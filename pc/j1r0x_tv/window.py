import json
import logging
import ctypes
import ctypes.wintypes
import re
import sys
import time
from collections import OrderedDict
from dataclasses import dataclass
from typing import Any
from urllib.parse import urljoin

import vlc
from PySide6.QtCore import (
    QEvent, QObject, QPoint, QSettings, Qt, QThread, QTimer, QUrl, Signal,
)
from PySide6.QtGui import QKeySequence, QShortcut
from PySide6.QtWidgets import (
    QApplication, QComboBox, QFrame, QGridLayout,
    QHBoxLayout, QLabel, QLineEdit, QMainWindow, QMessageBox,
    QPlainTextEdit, QPushButton, QScrollArea, QSizePolicy, QSlider,
    QStackedWidget, QTextEdit, QVBoxLayout, QWidget,
)

try:
    from PySide6.QtWebEngineWidgets import QWebEngineView
    WEB_ENGINE_AVAILABLE = True
except ImportError:
    QWebEngineView = None
    WEB_ENGINE_AVAILABLE = False

from .api import ApiClient
from .config import APP_NAME, POSTER_WIDTH, get_app_data_dir
from .database import LocalDatabase
from .models import MediaItem, SourceOption
from .utils import (
    choose_best_stream, collection_entries, extract_atodo_video_urls,
    extract_stream_candidates, extract_web_player_candidates, first_value,
)
from .widgets import CustomTitleBar, HistoryCard, ImageLabel, MediaCard
from .workers import TaskResultHandler, Worker


def _file_logger(name: str, filename: str, level: int) -> logging.Logger:
    logger = logging.getLogger(name)
    logger.setLevel(level)
    logger.propagate = False
    if logger.handlers:
        return logger

    try:
        log_dir = get_app_data_dir() / "logs"
        log_dir.mkdir(parents=True, exist_ok=True)
        handler = logging.FileHandler(log_dir / filename, encoding="utf-8")
    except OSError:
        handler = logging.StreamHandler()

    handler.setFormatter(logging.Formatter("%(asctime)s [%(levelname)s] %(message)s"))
    logger.addHandler(handler)
    return logger


debug_logger = _file_logger("j1r0xtv.debug", "app_debug.log", logging.INFO)
error_logger = _file_logger("j1r0xtv.error", "app_error.log", logging.ERROR)


@dataclass(frozen=True)
class QualityOption:
    label: str
    url: str
    height: int | None = None
    bandwidth: int | None = None
    is_auto: bool = False


@dataclass
class SeriesPlaybackContext:
    media_item: MediaItem
    provider_id: str
    source_id: str
    translation_id: str | None
    translation_name: str
    season: str
    episode: str
    season_index: int
    episode_index: int
    episodes: list[dict[str, Any]]
    seasons: list[dict[str, Any]]
    playback_generation: int


def natural_number(value: Any) -> int | None:
    """Extract a season/episode number while preserving unknown API ordering."""
    if isinstance(value, bool):
        return None
    if isinstance(value, int):
        return value
    match = re.search(r"(?<!\d)(\d+)(?!\d)", str(value or ""))
    return int(match.group(1)) if match else None


def naturally_ordered_entries(
    entries: list[tuple[str, dict[str, Any]]],
) -> list[tuple[str, dict[str, Any]]]:
    def entry_number(entry: tuple[str, dict[str, Any]]) -> int | None:
        key, child = entry
        for value in (
            key,
            first_value(
                child,
                (
                    "season_number", "episode_number", "season", "episode",
                    "number", "id", "season_name", "episode_name", "name", "title",
                ),
                "",
            ),
        ):
            number = natural_number(value)
            if number is not None:
                return number
        return None

    decorated = [
        (index, entry, entry_number(entry))
        for index, entry in enumerate(entries)
    ]
    decorated.sort(
        key=lambda item: (
            0 if item[2] is not None else 1,
            item[2] if item[2] is not None else item[0],
            item[0],
        )
    )
    return [entry for _, entry, _ in decorated]


class PlayerInputController(QObject):
    def __init__(self, window: "MainWindow") -> None:
        super().__init__(window)
        self.window = window

    def is_player_active(self) -> bool:
        return (
            not self.window._closing
            and self.window.stack.currentWidget() is self.window.player_page
        )

    def belongs_to_player(self, widget: QObject | None) -> bool:
        current = widget
        while current is not None:
            if current is self.window.player_page:
                return True
            current = current.parent()
        return False

    def handle_mouse_move(self) -> None:
        if not self.window._fullscreen_active:
            return
        debug_logger.debug("Mouse move fullscreen")
        self.show_controls()

    def show_controls(self) -> None:
        self.window.show_fullscreen_controls()

    def schedule_hide_controls(self) -> None:
        if self.window._fullscreen_active:
            self.window.controls_hide_timer.start()

    def hide_controls(self) -> None:
        self.window.hide_fullscreen_controls()

    def toggle_fullscreen(self) -> None:
        self.window.toggle_fullscreen()

    def enter_fullscreen(self) -> None:
        self.window.enter_fullscreen()

    def exit_fullscreen(self) -> None:
        self.window.exit_fullscreen()

    def eventFilter(self, watched, event) -> bool:
        if not self.is_player_active():
            return False
        event_type = event.type()
        if event_type in (
            QEvent.Type.MouseMove,
            QEvent.Type.Enter,
            QEvent.Type.HoverMove,
            QEvent.Type.MouseButtonPress,
        ) and self.belongs_to_player(watched):
            self.handle_mouse_move()
        elif event_type == QEvent.Type.Resize and watched is self.window.player_surface:
            self.window.position_player_overlays()
        elif (
            event_type == QEvent.Type.MouseButtonDblClick
            and watched is self.window.video_frame
            and event.button() == Qt.MouseButton.LeftButton
        ):
            self.toggle_fullscreen()
            return True
        elif (
            event_type == QEvent.Type.Wheel
            and watched is self.window.volume_slider
        ):
            self.window.adjust_player_volume(
                5 if event.angleDelta().y() > 0 else -5
            )
            return True
        return False

class MainWindow(QMainWindow):
    vlc_state_changed = Signal(str, float)
    series_finished = Signal(int)

    def __init__(self) -> None:
        super().__init__()
        debug_logger.info("startup MainWindow")
        self.setWindowFlags(Qt.WindowType.FramelessWindowHint)
        self.api = ApiClient()
        self.database = LocalDatabase()
        self._threads: list[QThread] = []
        self._workers: list[Worker] = []
        self._task_handlers: list[TaskResultHandler] = []
        self._closing = False
        self.current_items: list[MediaItem] = []
        self.catalog_cache: dict[str, list[MediaItem]] = {"movie": [], "tv": []}
        self.catalog_loaded = {"movie": False, "tv": False}
        self.catalog_loading = {"movie": False, "tv": False}
        self.source_list_cache: OrderedDict[
            tuple[str, str], list[SourceOption]
        ] = OrderedDict()
        self._source_list_cache_limit = 50
        self._media_cards_by_key: dict[tuple[str, str], list[MediaCard]] = {}
        self._catalog_generation = 0
        self._details_generation = 0
        self._source_generation = 0
        self._active_history: dict[str, Any] | None = None
        self._pending_resume: dict[str, Any] | None = None
        self._pending_seek_ms = 0
        self._last_history_save = 0.0
        self._quality_options: list[QualityOption] = []
        self._changing_quality = False
        self._quality_generation = 0
        self._current_stream_url = ""
        self._quality_switch: dict[str, Any] | None = None
        self._pause_after_seek = False
        self._fullscreen_geometry = None
        self._fullscreen_was_maximized = False
        self._fullscreen_active = False
        self._fullscreen_visibility: dict[QWidget, bool] = {}
        self._controls_hovered = False
        self.settings = QSettings("J1r0x", APP_NAME)
        try:
            saved_volume = int(self.settings.value("player/volume", 70))
        except (TypeError, ValueError):
            saved_volume = 70
        self._player_volume = max(0, min(100, saved_volume))
        self._last_nonzero_volume = self._player_volume or 70
        self._volume_muted = self._player_volume == 0
        self.series_playback_context: SeriesPlaybackContext | None = None
        self._pending_series_context: SeriesPlaybackContext | None = None
        self.auto_next_in_progress = False
        self.manual_start_in_progress = False
        self.playback_generation = 0
        self._last_handled_end_generation = -1
        self._pending_quality_height: int | None = None
        self._pending_quality_auto = True
        auto_next_value = self.settings.value("player/auto_next_episode", True)
        self.auto_next_episode = str(auto_next_value).lower() not in {
            "0", "false", "no", "off",
        }

        self.setWindowTitle(APP_NAME)
        self.resize(1280, 820)
        self.setMinimumSize(960, 620)

        root_container = QWidget()
        root_layout = QVBoxLayout(root_container)
        root_layout.setContentsMargins(0, 0, 0, 0)
        root_layout.setSpacing(0)
        self.title_bar = CustomTitleBar(self)
        self.stack = QStackedWidget()
        root_layout.addWidget(self.title_bar)
        root_layout.addWidget(self.stack, 1)
        self.setCentralWidget(root_container)

        self.catalog_page = self.build_catalog_page()
        self.details_page = self.build_details_page()
        self.player_page = self.build_player_page()

        self.stack.addWidget(self.catalog_page)
        self.stack.addWidget(self.details_page)
        self.stack.addWidget(self.player_page)
        self.setup_player_shortcuts()

        self.current_item: MediaItem | None = None
        self.current_source_payload: dict[str, Any] = {}
        self.current_translations: list[dict[str, Any]] = []
        self.vlc_instance = None
        self.vlc_player = None
        self.player_timer = None

        self.controls_hide_timer = QTimer(self)
        self.controls_hide_timer.setSingleShot(True)
        self.controls_hide_timer.setInterval(2500)
        self.overlay_hide_timer = QTimer(self)
        self.overlay_hide_timer.setSingleShot(True)
        self.overlay_hide_timer.timeout.connect(
            lambda: self.player_overlay.hide()
        )
        self.vlc_state_changed.connect(self.on_vlc_state_changed)
        self.series_finished.connect(
            self.handle_series_end,
            Qt.ConnectionType.QueuedConnection,
        )
        self.input_controller = PlayerInputController(self)
        self.controls_hide_timer.timeout.connect(
            self.input_controller.hide_controls
        )
        app = QApplication.instance()
        if app is not None:
            app.installEventFilter(self.input_controller)
        self.enable_player_mouse_tracking()

        self.apply_style()
        self.build_window_overlays()
        self.load_catalog("movie")

    def setup_player_shortcuts(self) -> None:
        """Create the application-wide player shortcuts exactly once."""
        self.player_shortcuts: list[QShortcut] = []

        def add_shortcut(sequence: str, callback) -> None:
            shortcut = QShortcut(QKeySequence(sequence), self)
            shortcut.setContext(Qt.ShortcutContext.ApplicationShortcut)
            shortcut.activated.connect(
                lambda name=sequence, action=callback:
                self.activate_player_shortcut(name, action)
            )
            self.player_shortcuts.append(shortcut)

        add_shortcut("Left", lambda: self.seek_relative(-10))
        add_shortcut("Right", lambda: self.seek_relative(10))
        add_shortcut("Up", lambda: self.adjust_player_volume(5))
        add_shortcut("Down", lambda: self.adjust_player_volume(-5))
        add_shortcut("Space", self.toggle_play_pause)
        add_shortcut("F", self.toggle_fullscreen)
        add_shortcut("Escape", self.exit_fullscreen)
        add_shortcut("M", self.toggle_mute)
        add_shortcut("J", lambda: self.seek_relative(-10))
        add_shortcut("L", lambda: self.seek_relative(10))
        add_shortcut("K", self.toggle_play_pause)

    def is_player_page_active(self) -> bool:
        return (
            not self._closing
            and self.stack.currentWidget() is self.player_page
        )

    def should_ignore_player_shortcut(self) -> bool:
        widget = QApplication.focusWidget()
        if isinstance(widget, (QLineEdit, QTextEdit, QPlainTextEdit)):
            return True
        for combo in self.player_page.findChildren(QComboBox):
            view = combo.view()
            if view is not None and view.isVisible():
                return True
        if isinstance(widget, QComboBox):
            if widget.isEditable():
                return True
        return False

    def activate_player_shortcut(self, name: str, callback) -> None:
        player_active = self.is_player_page_active()
        focused = QApplication.focusWidget()
        ignored = self.should_ignore_player_shortcut()
        debug_logger.debug("Shortcut activated: %s", name)
        debug_logger.debug("Player page active: %s", player_active)
        debug_logger.debug(
            "Focused widget: %s",
            type(focused).__name__ if focused is not None else "None",
        )
        debug_logger.debug("Ignored: %s", ignored)

        if name == "Escape":
            if self._fullscreen_active or self.isFullScreen():
                self.exit_fullscreen()
            return
        if not player_active or ignored:
            return
        callback()

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
        self.refresh_catalog_button = QPushButton("Обновить каталог")

        self.movies_button.clicked.connect(lambda: self.load_catalog("movie"))
        self.series_button.clicked.connect(lambda: self.load_catalog("tv"))
        self.favorites_button.clicked.connect(self.show_favorites)
        self.history_button.clicked.connect(self.show_history)
        self.refresh_catalog_button.clicked.connect(self.refresh_catalog)

        for button in (
            self.movies_button,
            self.series_button,
            self.favorites_button,
            self.history_button,
        ):
            button.setObjectName("navButton")
            nav.addWidget(button)

        nav.addStretch()
        nav.addWidget(self.refresh_catalog_button)
        self.clear_history_button = QPushButton("Очистить историю")
        self.clear_history_button.setObjectName("dangerButton")
        self.clear_history_button.clicked.connect(self.clear_history)
        self.clear_history_button.setVisible(False)
        nav.addWidget(self.clear_history_button)

        self.section_title = QLabel("Популярные фильмы")
        self.section_title.setObjectName("sectionTitle")

        self.status_label = QLabel("")
        self.status_label.setObjectName("status")

        self.scroll = QScrollArea()
        self.scroll.setWidgetResizable(True)
        self.scroll.setFrameShape(QFrame.Shape.NoFrame)
        self.scroll.setVerticalScrollBarPolicy(
            Qt.ScrollBarPolicy.ScrollBarAlwaysOff
        )

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
        self.details_favorite_button = QPushButton("☆ В избранное")
        self.details_favorite_button.clicked.connect(
            lambda: self.toggle_favorite(self.current_item)
        )

        text_layout.addWidget(self.details_title)
        text_layout.addWidget(self.details_meta)
        text_layout.addSpacing(12)
        text_layout.addWidget(self.details_overview)
        text_layout.addStretch()
        detail_actions = QHBoxLayout()
        detail_actions.addWidget(self.play_button)
        detail_actions.addWidget(self.details_favorite_button)
        detail_actions.addStretch()
        text_layout.addLayout(detail_actions)

        content.addWidget(self.details_poster)
        content.addLayout(text_layout, 1)

        root.addLayout(top)
        root.addLayout(content, 1)
        return page

    def build_player_page(self) -> QWidget:
        page = QWidget()
        root = QVBoxLayout(page)
        self.player_root_layout = root
        root.setContentsMargins(20, 16, 20, 20)
        root.setSpacing(12)

        self.player_top_bar = QWidget()
        top = QHBoxLayout(self.player_top_bar)
        top.setContentsMargins(0, 0, 0, 0)

        back = QPushButton("← К фильму")
        back.setObjectName("navButton")
        back.clicked.connect(self.leave_player)

        self.player_title = QLabel("Плеер")
        self.player_title.setObjectName("sectionTitle")

        top.addWidget(back)
        top.addWidget(self.player_title)
        top.addStretch()

        self.player_selectors = QWidget()
        selectors = QHBoxLayout(self.player_selectors)
        selectors.setContentsMargins(0, 0, 0, 0)

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

        self.play_stream_button = QPushButton("▶ Смотреть")
        self.play_stream_button.setObjectName("primaryButton")
        self.play_stream_button.clicked.connect(
            lambda: self.play_selected_stream(manual=True)
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
        self.video_frame.setMinimumSize(0, 0)
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

        self.player_surface = QWidget()
        self.player_surface.setObjectName("playerSurface")
        surface_layout = QVBoxLayout(self.player_surface)
        surface_layout.setContentsMargins(0, 0, 0, 0)
        surface_layout.addWidget(self.player_view_stack, 1)

        self.player_controls = QWidget(self.player_surface)
        self.player_controls.setObjectName("playerControls")
        controls = QHBoxLayout(self.player_controls)
        controls.setContentsMargins(12, 8, 12, 8)
        controls.setSpacing(8)

        self.play_pause_button = QPushButton("▶")
        self.play_pause_button.setObjectName("playPauseButton")
        self.play_pause_button.setToolTip("Воспроизведение/пауза (Space)")
        self.play_pause_button.clicked.connect(self.toggle_play_pause)

        self.position_slider = QSlider(Qt.Orientation.Horizontal)
        self.position_slider.setRange(0, 1000)
        self.position_slider.sliderReleased.connect(self.seek_video)

        self.time_label = QLabel("00:00 / 00:00")
        self.time_label.setObjectName("cardMeta")

        self.volume_button = QPushButton()
        self.volume_button.setObjectName("volumeButton")
        self.volume_button.setToolTip("Выключить/включить звук (M)")
        self.volume_button.clicked.connect(self.toggle_mute)

        self.volume_controls = QWidget()
        self.volume_controls.setObjectName("volumeControls")
        volume_layout = QHBoxLayout(self.volume_controls)
        volume_layout.setContentsMargins(4, 0, 6, 0)
        volume_layout.setSpacing(6)
        self.volume_slider = QSlider(Qt.Orientation.Horizontal)
        self.volume_slider.setObjectName("volumeSlider")
        self.volume_slider.setRange(0, 100)
        self.volume_slider.setFixedWidth(105)
        self.volume_slider.valueChanged.connect(self.set_player_volume)
        self.volume_label = QLabel()
        self.volume_label.setObjectName("volumeValue")
        self.volume_label.setFixedWidth(38)
        volume_layout.addWidget(self.volume_slider)
        volume_layout.addWidget(self.volume_label)
        self.update_volume_ui()

        self.fullscreen_button = QPushButton("Полный экран")
        self.fullscreen_button.clicked.connect(self.toggle_fullscreen)

        self.quality_combo = QComboBox()
        self.quality_combo.setToolTip("Выбор качества видео")
        self.quality_combo.setMinimumWidth(115)
        self.quality_combo.addItem("Качество")
        self.quality_combo.setEnabled(False)
        self.quality_combo.currentIndexChanged.connect(
            self.on_quality_selected
        )

        controls.addWidget(self.play_pause_button)
        controls.addWidget(self.volume_button)
        controls.addWidget(self.volume_controls)
        controls.addWidget(self.position_slider, 1)
        controls.addWidget(self.time_label)
        controls.addWidget(self.quality_combo)
        controls.addWidget(self.fullscreen_button)
        surface_layout.addWidget(self.player_controls, 0)

        self.player_overlay = QLabel(self.player_surface)
        self.player_overlay.setObjectName("playerOverlay")
        self.player_overlay.setAlignment(Qt.AlignmentFlag.AlignCenter)
        self.player_overlay.hide()

        root.addWidget(self.player_top_bar)
        root.addWidget(self.player_selectors)
        root.addWidget(self.player_status)
        root.addWidget(self.player_surface, 1)

        self.player_surface.setMouseTracking(True)
        self.video_frame.setMouseTracking(True)
        self.video_frame.setFocusPolicy(Qt.FocusPolicy.StrongFocus)

        return page

    def enable_player_mouse_tracking(self) -> None:
        self.setMouseTracking(True)
        self.player_page.setMouseTracking(True)
        for widget in self.player_page.findChildren(QWidget):
            widget.setMouseTracking(True)
            widget.setAttribute(Qt.WidgetAttribute.WA_Hover, True)

    def focus_video_surface(self) -> None:
        for widget in (
            self.source_combo, self.translation_combo, self.season_combo,
            self.episode_combo, self.play_stream_button,
        ):
            widget.clearFocus()
        self.video_frame.setFocus(Qt.FocusReason.OtherFocusReason)

    def open_watch_page(self, force_source_refresh: bool = False) -> None:
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
        self.set_quality_options([])
        self.play_stream_button.setEnabled(True)
        self.play_stream_button.show()

        self._source_generation += 1
        generation = self._source_generation
        cache_key = (self.current_item.media_type, self.current_item.item_id)
        cached_sources = self.source_list_cache.get(cache_key)
        if cached_sources is not None and not force_source_refresh:
            self.source_list_cache.move_to_end(cache_key)
            debug_logger.info("Source list cache hit: %s", cache_key)
            self.apply_source_list(cached_sources)
            return
        selected_item = self.current_item
        self.run_task(
            lambda: self.api.source_list(selected_item),
            lambda sources: self._apply_and_cache_source_list(
                cache_key, sources, generation
            ),
            lambda message: self.on_task_failed(message)
            if generation == self._source_generation else None,
        )

    def _apply_and_cache_source_list(
        self,
        cache_key: tuple[str, str],
        sources: list[SourceOption],
        generation: int,
    ) -> None:
        if generation != self._source_generation:
            return
        self.source_list_cache[cache_key] = list(sources)
        self.source_list_cache.move_to_end(cache_key)
        while len(self.source_list_cache) > self._source_list_cache_limit:
            self.source_list_cache.popitem(last=False)
        self.apply_source_list(sources)

    def apply_source_list(
        self,
        sources: list[SourceOption],
    ) -> None:
        prepared_tv_item = self.api.prepared_tv_item
        if (
            self.current_item is not None
            and self.current_item.media_type == "tv"
            and prepared_tv_item is not None
            and prepared_tv_item.item_id == self.current_item.item_id
        ):
            self.current_item = prepared_tv_item

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
        source_index = 0
        if self._pending_resume:
            wanted = self._pending_resume.get("source_id", "")
            for index in range(self.source_combo.count()):
                option = self.source_combo.itemData(index)
                if isinstance(option, SourceOption) and option.source_id == wanted:
                    source_index = index
                    break
        self.source_combo.setCurrentIndex(source_index)

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
        self.play_stream_button.setEnabled(True)
        self.play_stream_button.show()

        self._source_generation += 1
        generation = self._source_generation
        selected_item = self.current_item
        self.run_task(
            lambda: self.api.source_get(
                selected_item,
                source.source_id,
            ),
            lambda payload: self.apply_source_payload(payload)
            if generation == self._source_generation else None,
            lambda message: self.on_source_failed(message)
            if generation == self._source_generation else None,
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
            + (
                "Создан series_trace.json."
                if self.current_item and self.current_item.media_type == "tv"
                else "Создан failed_source_debug.json."
            )
        )

    def apply_source_payload(
        self,
        payload: dict[str, Any],
    ) -> None:
        self.current_source_payload = payload

        try:
            debug_dir = get_app_data_dir() / "debug"
            debug_dir.mkdir(parents=True, exist_ok=True)
            debug_path = debug_dir / "source_debug.json"

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
        if self._pending_resume:
            QTimer.singleShot(0, self._restore_resume_selection)

    def continue_history(self, entry: dict[str, Any]) -> None:
        item = entry.get("item")
        if not isinstance(item, MediaItem):
            return
        self._pending_resume = entry
        self._pending_seek_ms = int(entry.get("position_ms", 0))
        debug_logger.info(
            "history resume: provider=%s source=%s translation=%s season=%s episode=%s",
            entry.get("provider_id", ""), entry.get("source_id", ""),
            entry.get("translation_name", ""), entry.get("season", ""),
            entry.get("episode", ""),
        )
        self.run_task(
            lambda: self.api.details(item.media_type, item.item_id),
            lambda details: self._continue_history_with_details(entry, details),
            lambda message: self._continue_history_failed(message),
        )

    def _continue_history_with_details(
        self, entry: dict[str, Any], details: MediaItem
    ) -> None:
        debug_logger.info("history resume: media found")
        self.current_item = details
        self._pending_resume = entry
        self.open_watch_page(force_source_refresh=True)

    def _continue_history_failed(self, message: str) -> None:
        error_logger.error("History resume details failed: %s", message)
        self._pending_resume = None
        self._pending_seek_ms = 0
        QMessageBox.warning(self, APP_NAME, "Не удалось обновить данные для продолжения.")

    def _restore_resume_selection(self) -> None:
        entry = self._pending_resume
        if not entry:
            return

        translation_id = str(entry.get("translation_id", ""))
        translation = str(entry.get("translation_name", ""))
        index = -1
        if translation_id:
            for candidate in range(self.translation_combo.count()):
                value = self.translation_combo.itemData(candidate)
                if isinstance(value, dict) and str(first_value(
                    value, ("translation_id", "id", "key"), ""
                )) == translation_id:
                    index = candidate
                    break
        if index < 0:
            index = self.translation_combo.findText(translation)
        if index < 0 and self.translation_combo.count():
            debug_logger.info("history resume: translation fallback to first available")
        self.translation_combo.setCurrentIndex(index if index >= 0 else 0)

        season = str(entry.get("season", ""))
        index = self.season_combo.findText(season)
        if index >= 0:
            self.season_combo.setCurrentIndex(index)

        episode = str(entry.get("episode", ""))
        index = self.episode_combo.findText(episode)
        if index >= 0:
            self.episode_combo.setCurrentIndex(index)

        if self.selected_stream_container():
            container = self.selected_stream_container()
            debug_logger.info(
                "history resume: episode found data=%s streams=%s",
                bool(container.get("data")), bool(container.get("streams")),
            )
            self.play_selected_stream()

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
        season_entries = collection_entries(
            seasons,
            ("season_number", "season", "number", "id"),
        )
        season_entries = naturally_ordered_entries(season_entries)

        if season_entries:
            for key, season in season_entries:
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
        episode_entries = collection_entries(
            episodes,
            ("episode_number", "episode", "number", "id"),
        )
        episode_entries = naturally_ordered_entries(episode_entries)

        for key, episode in episode_entries:
            name = str(
                first_value(
                    episode,
                    ("episode_name", "name", "title"),
                    f"Серия {key}",
                )
            )
            self.episode_combo.addItem(name, episode)
        if self.episode_combo.count():
            self.episode_combo.setCurrentIndex(0)

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

        if isinstance(data_value, dict) and data_value:
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
                "--no-mouse-events",
                "--network-caching=2500",
            )
            self.vlc_player = self.vlc_instance.media_player_new()
            self.vlc_player.audio_set_volume(self._player_volume)
            self.vlc_player.video_set_scale(0)
            self.vlc_player.video_set_aspect_ratio(None)

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

            event_manager = self.vlc_player.event_manager()
            event_map = {
                vlc.EventType.MediaPlayerOpening: "opening",
                vlc.EventType.MediaPlayerBuffering: "buffering",
                vlc.EventType.MediaPlayerPlaying: "playing",
                vlc.EventType.MediaPlayerPaused: "paused",
                vlc.EventType.MediaPlayerStopped: "stopped",
                vlc.EventType.MediaPlayerEncounteredError: "error",
            }
            for event_type, state in event_map.items():
                event_manager.event_attach(
                    event_type,
                    lambda event, name=state: self.vlc_state_changed.emit(
                        name,
                        float(getattr(getattr(event, "u", None), "new_cache", 0.0)),
                    ),
                )
            event_manager.event_attach(
                vlc.EventType.MediaPlayerEndReached,
                self.on_vlc_end_reached,
            )
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

    def on_vlc_end_reached(self, event) -> None:
        """VLC-thread callback: emit Qt signals only, never touch widgets."""
        generation = self.playback_generation
        self.vlc_state_changed.emit("ended", 0.0)
        self.series_finished.emit(generation)

    def set_player_volume(self, value: int, persist: bool = True) -> None:
        """Set the application volume and keep VLC and all controls in sync."""
        value = max(0, min(100, int(value)))
        self._player_volume = value
        self._volume_muted = value == 0
        if value > 0:
            self._last_nonzero_volume = value
        if persist:
            self.settings.setValue("player/volume", value)
        if self.vlc_player is not None:
            self.vlc_player.audio_set_volume(value)
        self.update_volume_ui()
        if persist and self.stack.currentWidget() is self.player_page:
            self.show_player_overlay(f"Громкость {value}%")

    def toggle_mute(self) -> None:
        if self._volume_muted or self._player_volume == 0:
            self.set_player_volume(self._last_nonzero_volume)
        else:
            self._last_nonzero_volume = self._player_volume
            # Muting is temporary: retain the last audible value in settings.
            self.set_player_volume(0, persist=False)
            self.show_player_overlay("Звук выключен")

    def update_volume_ui(self) -> None:
        value = self._player_volume
        icon = "🔇" if value == 0 else "🔈" if value < 34 else "🔉" if value < 67 else "🔊"
        self.volume_button.setText(icon)
        self.volume_label.setText(f"{value}%")
        if self.volume_slider.value() != value:
            self.volume_slider.blockSignals(True)
            self.volume_slider.setValue(value)
            self.volume_slider.blockSignals(False)

    def adjust_player_volume(self, delta: int) -> None:
        base = 0 if self._volume_muted else self._player_volume
        self.set_player_volume(base + delta)

    def selected_series_context(self, generation: int) -> SeriesPlaybackContext | None:
        if not self.current_item or self.current_item.media_type != "tv":
            return None
        season_index = self.season_combo.currentIndex()
        episode_index = self.episode_combo.currentIndex()
        if season_index < 0 or episode_index < 0:
            return None
        translation = self.translation_combo.currentData()
        if not isinstance(translation, dict):
            translation = {}
        translation_id = first_value(translation, ("translation_id", "id", "key"), "")
        raw = self.current_item.raw or {}
        return SeriesPlaybackContext(
            media_item=self.current_item,
            provider_id=str(first_value(raw, ("provider_id", "provider"), "atodo")),
            source_id=self.current_source_id(),
            translation_id=str(translation_id) if translation_id else None,
            translation_name=self.translation_combo.currentText(),
            season=self.season_combo.currentText(),
            episode=self.episode_combo.currentText(),
            season_index=season_index,
            episode_index=episode_index,
            episodes=[self.episode_combo.itemData(i) for i in range(self.episode_combo.count())],
            seasons=[self.season_combo.itemData(i) for i in range(self.season_combo.count())],
            playback_generation=generation,
        )

    def set_stream_launch_pending(self, pending: bool) -> None:
        self.play_stream_button.setEnabled(not pending)
        self.play_stream_button.setText(
            "Загрузка..." if pending else "▶ Смотреть"
        )
        self.play_stream_button.show()

    def finish_stream_launch(self) -> None:
        self.manual_start_in_progress = False
        self.auto_next_in_progress = False
        self._pending_series_context = None
        self.set_stream_launch_pending(False)

    def play_selected_stream(self, manual: bool = True) -> None:
        if self._closing:
            return
        if manual:
            self.auto_next_in_progress = False
            self.manual_start_in_progress = True
            self.save_current_progress(force=True)
            if self.vlc_player is not None and self.vlc_player.get_media() is not None:
                self.vlc_player.stop()
                self.update_play_pause_button()
            self._active_history = None
        else:
            if self.auto_next_in_progress:
                return
            self.auto_next_in_progress = True
        self.playback_generation += 1
        generation = self.playback_generation
        quality = self.current_quality_option()
        self._pending_quality_height = quality.height if quality else None
        self._pending_quality_auto = quality.is_auto if quality else True
        self._pending_series_context = self.selected_series_context(generation)
        self.set_stream_launch_pending(True)
        container = self.selected_stream_container()

        streams_value = (
            container.get("streams")
            if isinstance(container, dict)
            else None
        )

        stream_container = (
            streams_value if streams_value is not None else container
        )
        is_tv = bool(
            self.current_item and self.current_item.media_type == "tv"
        )
        urls = (
            extract_atodo_video_urls(stream_container)
            if is_tv
            else extract_stream_candidates(stream_container)
        )

        data_hash = self.extract_data_hash(container)
        source_id = self.current_source_id()

        if is_tv and data_hash and source_id:
            self.player_status.setText("Получаю видеопоток серии...")
            self.run_task(
                lambda: self.api.resolve_streams(source_id, data_hash),
                lambda payload: self.apply_resolved_streams(payload, generation)
                if generation == self.playback_generation else None,
                lambda message: self.on_resolve_stream_failed(message, generation)
                if generation == self.playback_generation else None,
            )
            return

        if urls:
            preferred = self.preferred_stream_url(stream_container, urls, is_tv)
            self.configure_quality_options(
                stream_container, urls, preferred
            )
            self.start_direct_stream(preferred, launch_generation=generation)
            return

        if data_hash and source_id:
            self.player_status.setText(
                "Получаю видеопоток по токену..."
            )
            self.run_task(
                lambda: self.api.resolve_streams(
                    source_id,
                    data_hash,
                ),
                lambda payload: self.apply_resolved_streams(payload, generation)
                if generation == self.playback_generation else None,
                lambda message: self.on_resolve_stream_failed(message, generation)
                if generation == self.playback_generation else None,
            )
            return

        web_urls = extract_web_player_candidates(container)

        if not web_urls:
            web_urls = extract_web_player_candidates(
                self.current_source_payload
            )

        if web_urls:
            self.open_embedded_web_player(web_urls[0])
            self.finish_stream_launch()
            return

        QMessageBox.warning(
            self,
            APP_NAME,
            (
                "Источник не передал токен или прямой видеопоток.\n"
                "Попробуй другую озвучку или источник."
            ),
        )
        self.finish_stream_launch()

    def apply_resolved_streams(
        self,
        payload: dict[str, Any],
        generation: int,
    ) -> None:
        if generation != self.playback_generation:
            return

        try:
            debug_dir = get_app_data_dir() / "debug"
            debug_dir.mkdir(parents=True, exist_ok=True)
            debug_path = debug_dir / "resolved_stream_debug.json"

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
        is_tv = bool(
            self.current_item and self.current_item.media_type == "tv"
        )
        urls = (
            extract_atodo_video_urls(streams)
            if is_tv
            else extract_stream_candidates(streams)
        )

        if not urls:
            web_urls = extract_web_player_candidates(payload)

            if web_urls:
                self.open_embedded_web_player(web_urls[0])
                self.finish_stream_launch()
                return

            self.player_status.setText(
                "Не удалось запустить следующую серию"
                if self.auto_next_in_progress
                else "Сервер ответил, но поток не найден."
            )
            if not self.auto_next_in_progress:
                QMessageBox.warning(
                    self,
                    APP_NAME,
                    (
                        "Atodo принял токен, но не вернул распознаваемый поток.\n"
                        "Создан файл debug/resolved_stream_debug.json в папке данных приложения."
                    ),
                )
            self.finish_stream_launch()
            return

        preferred = self.preferred_stream_url(streams, urls, is_tv)
        self.configure_quality_options(streams, urls, preferred)
        self.start_direct_stream(preferred, launch_generation=generation)

    def on_resolve_stream_failed(
        self,
        message: str,
        generation: int,
    ) -> None:
        if generation != self.playback_generation:
            return
        self.player_status.setText(
            "Не удалось запустить следующую серию"
            if self.auto_next_in_progress
            else "Не удалось получить видеопоток."
        )
        if not self.auto_next_in_progress:
            QMessageBox.warning(self, APP_NAME, message)
        self._pending_series_context = None
        self.finish_stream_launch()

    def preferred_stream_url(
        self,
        streams: Any,
        urls: list[str],
        is_tv: bool,
    ) -> str:
        default = urls[0] if is_tv else choose_best_stream(urls)
        if not is_tv:
            return default
        options, _ = self.build_quality_options(streams, urls, default)
        if self._pending_quality_auto:
            auto = next((option for option in options if option.is_auto), None)
            return auto.url if auto else default
        if self._pending_quality_height is not None:
            match = next(
                (option for option in options if option.height == self._pending_quality_height),
                None,
            )
            if match is not None:
                return match.url
        return default

    @staticmethod
    def quality_height(value: Any) -> int | None:
        text = str(value or "")
        match = re.search(
            r"(?<!\d)(2160|1440|1080|720|576|480|360|240)p?(?!\d)",
            text,
            re.IGNORECASE,
        )
        return int(match.group(1)) if match else None

    @staticmethod
    def quality_label(height: int | None) -> str:
        if height == 2160:
            return "2160p / 4K"
        return f"{height}p" if height else "Другой поток"

    def build_quality_options(
        self,
        streams: Any,
        urls: list[str],
        preferred_url: str,
    ) -> tuple[list[QualityOption], str]:
        root = streams.get("streams", streams) if isinstance(streams, dict) else streams
        video = root.get("video", {}) if isinstance(root, dict) else {}
        hls = video.get("hls", {}) if isinstance(video, dict) else {}
        http = video.get("http", {}) if isinstance(video, dict) else {}
        master_url = ""
        if isinstance(hls, dict):
            masters = extract_stream_candidates(hls.get("master"))
            master_url = masters[0] if masters else ""

        variants: dict[str, QualityOption] = {}

        def collect(node: Any, hint: Any = "") -> None:
            if isinstance(node, dict):
                direct = extract_stream_candidates(node)
                if direct and any(key in node for key in ("url", "file", "src")):
                    height = self.quality_height(
                        first_value(node, ("height", "quality", "resolution", "label"), hint)
                    ) or self.quality_height(direct[0])
                    variants.setdefault(
                        direct[0],
                        QualityOption(self.quality_label(height), direct[0], height),
                    )
                    return
                for key, child in node.items():
                    collect(child, key)
                return
            if isinstance(node, (list, tuple)):
                for child in node:
                    collect(child, hint)
                return
            if isinstance(node, str):
                candidates = extract_stream_candidates({str(hint): node})
                for url in candidates:
                    height = self.quality_height(hint) or self.quality_height(url)
                    variants.setdefault(
                        url,
                        QualityOption(self.quality_label(height), url, height),
                    )

        if isinstance(hls, dict):
            collect(hls.get("qualities"), "")
        if isinstance(http, dict):
            collect(http.get("qualities"), "")
        for url in urls:
            if url != master_url:
                height = self.quality_height(url)
                if height:
                    variants.setdefault(
                        url, QualityOption(self.quality_label(height), url, height)
                    )

        auto_url = master_url or preferred_url
        options = [QualityOption("Авто", auto_url, is_auto=True)]
        sorted_variants = sorted(
            variants.values(),
            key=lambda option: (option.height is None, option.height or 0, option.bandwidth or 0),
        )
        if len(sorted_variants) > 1 or master_url:
            options.extend(option for option in sorted_variants if option.url != master_url)
        return options, master_url

    def configure_quality_options(
        self,
        streams: Any,
        urls: list[str],
        preferred_url: str,
    ) -> None:
        options, master_url = self.build_quality_options(
            streams, urls, preferred_url
        )
        self.set_quality_options(options, preferred_url)
        self._quality_generation += 1
        generation = self._quality_generation
        if master_url:
            self.run_task(
                lambda: self.load_hls_master(master_url),
                lambda variants: self.apply_hls_variants(
                    master_url, variants, generation
                ),
                lambda message: debug_logger.info(
                    "HLS master quality discovery failed: %s", message
                ),
            )

    def set_quality_options(
        self,
        options: list[QualityOption],
        selected_url: str = "",
    ) -> None:
        self._quality_options = options
        self.quality_combo.blockSignals(True)
        self.quality_combo.clear()
        for option in options:
            self.quality_combo.addItem(option.label, option)
        if options:
            selected_index = next(
                (index for index, option in enumerate(options) if option.url == selected_url),
                0,
            )
            self.quality_combo.setCurrentIndex(selected_index)
            self.quality_combo.setEnabled(len(options) > 1)
        else:
            self.quality_combo.addItem("Авто")
            self.quality_combo.setEnabled(False)
        self.quality_combo.blockSignals(False)

    def load_hls_master(self, master_url: str) -> list[QualityOption]:
        playlist = self.api.get_text_url(
            master_url,
            headers={
                "User-Agent": "Mozilla/5.0",
                "Referer": "https://atodo.fun/",
            },
            timeout=12,
        )
        lines = [line.strip() for line in playlist.splitlines()]
        result: dict[str, QualityOption] = {}
        for index, line in enumerate(lines):
            if not line.startswith("#EXT-X-STREAM-INF:"):
                continue
            attributes = line.split(":", 1)[1]
            resolution = re.search(r"RESOLUTION=\d+x(\d+)", attributes, re.I)
            bandwidth = re.search(r"(?:AVERAGE-)?BANDWIDTH=(\d+)", attributes, re.I)
            variant_line = next(
                (candidate for candidate in lines[index + 1:] if candidate and not candidate.startswith("#")),
                "",
            )
            if not variant_line:
                continue
            url = urljoin(master_url, variant_line)
            height = int(resolution.group(1)) if resolution else None
            bitrate = int(bandwidth.group(1)) if bandwidth else None
            label = MainWindow.quality_label(height)
            result[url] = QualityOption(label, url, height, bitrate)
        return sorted(
            result.values(),
            key=lambda option: (option.height is None, option.height or 0, option.bandwidth or 0),
        )

    def apply_hls_variants(
        self,
        master_url: str,
        variants: list[QualityOption],
        generation: int,
    ) -> None:
        if generation != self._quality_generation or not variants:
            return
        current = self.current_quality_option()
        options = [QualityOption("Авто", master_url, is_auto=True)]
        seen = {master_url}
        for option in variants + [item for item in self._quality_options if not item.is_auto]:
            if option.url not in seen:
                options.append(option)
                seen.add(option.url)
        self.set_quality_options(options, current.url if current else master_url)

    def current_quality_option(self) -> QualityOption | None:
        option = self.quality_combo.currentData()
        return option if isinstance(option, QualityOption) else None

    def on_quality_selected(self, index: int) -> None:
        option = self.quality_combo.itemData(index)
        if (
            not isinstance(option, QualityOption)
            or self._changing_quality
            or option.url == self._current_stream_url
            or not self.vlc_player
            or self.vlc_player.get_media() is None
        ):
            return
        current_time = max(0, self.vlc_player.get_time())
        was_playing = bool(self.vlc_player.is_playing())
        self._quality_switch = {
            "old_url": self._current_stream_url,
            "new_url": option.url,
            "position_ms": current_time,
            "was_playing": was_playing,
        }
        self._changing_quality = True
        self._pending_seek_ms = current_time
        self._pause_after_seek = not was_playing
        self.player_status.setText(f"Переключаю качество: {option.label}…")
        self.start_direct_stream(option.url, quality_switch=True)

    def start_direct_stream(
        self,
        url: str,
        quality_switch: bool = False,
        launch_generation: int | None = None,
    ) -> None:
        if not url:
            if launch_generation is not None:
                self.finish_stream_launch()
            return

        if (
            launch_generation is not None
            and launch_generation != self.playback_generation
        ):
            return

        if not self.init_vlc():
            if launch_generation is not None:
                self.finish_stream_launch()
            return

        self.player_view_stack.setCurrentWidget(
            self.video_frame
        )

        media = self.vlc_instance.media_new(url)
        media.add_option(":http-user-agent=Mozilla/5.0")
        media.add_option(":http-referrer=https://atodo.fun/")
        media.add_option(":network-caching=2500")

        if self.vlc_player.get_media() is not None:
            self.save_current_progress(force=True)
            self.vlc_player.stop()
        self.vlc_player.set_media(media)
        self._current_stream_url = url
        result = self.vlc_player.play()
        # VLC can reset audio state while attaching a new media stream.
        self.set_player_volume(self._player_volume, persist=False)
        QTimer.singleShot(
            250,
            self._apply_started_player_state,
        )

        if result == -1:
            self.player_status.setText("Не удалось запустить воспроизведение.")
            self.update_play_pause_button()
            if quality_switch:
                self.rollback_quality_switch()
            if launch_generation is not None:
                self._pending_series_context = None
                self.finish_stream_launch()
            return

        if launch_generation is not None:
            pending_context = self._pending_series_context
            self.series_playback_context = (
                pending_context
                if (
                    pending_context is not None
                    and pending_context.playback_generation == launch_generation
                )
                else None
            )
        self._pending_series_context = None

        if self.current_item is not None and not quality_switch:
            resume = self._pending_resume or {}
            season = str(
                resume.get("season")
                or (self.season_combo.currentText() if self.season_combo.isVisible() else "")
            )
            episode = str(
                resume.get("episode")
                or (self.episode_combo.currentText() if self.episode_combo.isVisible() else "")
            )
            source_id = self.current_source_id() or str(resume.get("source_id", ""))
            translation = (
                self.translation_combo.currentText()
                or str(resume.get("translation_name", ""))
            )
            translation_data = self.translation_combo.currentData()
            translation_id = str(first_value(
                translation_data if isinstance(translation_data, dict) else {},
                ("translation_id", "id", "key"),
                resume.get("translation_id", ""),
            ))
            raw = self.current_item.raw or {}
            provider_id = str(first_value(
                raw, ("provider_id", "provider"), resume.get("provider_id", "atodo")
            ))
            self._active_history = {
                "item": self.current_item,
                "source_id": source_id,
                "translation_name": translation,
                "season": season,
                "episode": episode,
                "stream_url": url,
            }
            initial_position = max(
                int(resume.get("position_ms", 0)),
                self._pending_seek_ms,
            )
            self._pending_seek_ms = max(self._pending_seek_ms, initial_position)
            self.database.save_history(
                self.current_item,
                source_id=source_id,
                provider_id=provider_id,
                translation_id=translation_id,
                translation_name=translation,
                season=season,
                episode=episode,
                stream_url=url,
                position_ms=initial_position,
                duration_ms=int(resume.get("duration_ms", 0)),
            )
            self._pending_resume = None
            self._last_history_save = time.monotonic()
        elif quality_switch and self._active_history is not None:
            self._active_history["stream_url"] = url

        if launch_generation is not None:
            self.finish_stream_launch()
        else:
            self.play_stream_button.show()
        self.focus_video_surface()
        self.player_status.setText("Загрузка…")

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
            self.update_play_pause_button()

        self.series_playback_context = None
        self._pending_series_context = None

        self.web_player.setUrl(QUrl(url))
        self.player_view_stack.setCurrentWidget(
            self.web_player
        )
        self.player_status.setText(
            "Открыт встроенный веб-плеер источника."
        )

    def toggle_play_pause(self) -> None:
        if not self.vlc_player:
            self.update_play_pause_button()
            return

        try:
            if self.vlc_player.is_playing():
                self.vlc_player.pause()
            else:
                result = self.vlc_player.play()
                if result == -1:
                    self.player_status.setText("Не удалось продолжить воспроизведение.")
        finally:
            QTimer.singleShot(0, self.update_play_pause_button)
            QTimer.singleShot(150, self.update_play_pause_button)

    def update_play_pause_button(self) -> None:
        playing = False
        if self.vlc_player is not None:
            try:
                playing = bool(self.vlc_player.is_playing())
            except Exception:
                playing = False
        self.play_pause_button.setText("❚❚" if playing else "▶")

    def _apply_started_player_state(self) -> None:
        if self.vlc_player is not None:
            self.vlc_player.audio_set_volume(self._player_volume)
        self.update_volume_ui()
        self.update_play_pause_button()

    def select_series(self, season_index: int, episode_index: int) -> bool:
        if not (0 <= season_index < self.season_combo.count()):
            return False
        self.season_combo.blockSignals(True)
        self.season_combo.setCurrentIndex(season_index)
        self.season_combo.blockSignals(False)
        self.on_season_selected(season_index)
        if not (0 <= episode_index < self.episode_combo.count()):
            return False
        self.episode_combo.blockSignals(True)
        self.episode_combo.setCurrentIndex(episode_index)
        self.episode_combo.blockSignals(False)
        return True

    def next_series_selection(
        self,
        context: SeriesPlaybackContext,
    ) -> tuple[int, int] | None:
        if context.episode_index + 1 < len(context.episodes):
            return context.season_index, context.episode_index + 1
        if context.season_index + 1 < len(context.seasons):
            return context.season_index + 1, 0
        return None

    def handle_series_end(self, ended_generation: int) -> None:
        """Handle VLC completion in the Qt GUI thread."""
        context = self.series_playback_context
        if (
            self._closing
            or self.manual_start_in_progress
            or self.auto_next_in_progress
            or not self.is_player_page_active()
            or context is None
            or context.media_item.media_type != "tv"
            or context.playback_generation != ended_generation
            or context.playback_generation == self._last_handled_end_generation
        ):
            return
        self._last_handled_end_generation = context.playback_generation
        self.database.remove_history(
            context.media_item.item_id,
            context.media_item.media_type,
            context.season,
            context.episode,
        )
        self._active_history = None
        self.update_play_pause_button()

        next_selection = self.next_series_selection(context)
        if next_selection is None:
            self.player_status.setText("Сериал просмотрен")
            self.play_pause_button.setText("▶")
            self.set_stream_launch_pending(False)
            return

        if not self.select_series(*next_selection):
            self.player_status.setText("Не удалось выбрать следующую серию")
            self.set_stream_launch_pending(False)
            return

        season_number = natural_number(self.season_combo.currentText())
        episode_number = natural_number(self.episode_combo.currentText())
        next_label = (
            f"S{season_number or self.season_combo.currentIndex() + 1}"
            f"E{episode_number or self.episode_combo.currentIndex() + 1}"
        )
        if not self.auto_next_episode:
            self.player_status.setText(
                f"Выбрана следующая серия: {next_label}"
            )
            self.play_pause_button.setText("▶")
            return

        self._pending_resume = None
        self._pending_seek_ms = 0
        self._pause_after_seek = False
        self.position_slider.setValue(0)
        self.time_label.setText("00:00 / 00:00")
        self.player_status.setText(
            f"Запускается следующая серия: {next_label}"
        )
        self.play_selected_stream(manual=False)

    def on_vlc_state_changed(self, state: str, buffering: float = 0.0) -> None:
        if state == "opening":
            self.player_status.setText("Загрузка…")
        elif state == "buffering":
            self.player_status.setText(
                f"Буферизация… {max(0, min(100, int(buffering)))}%"
            )
        elif state == "playing":
            self.player_status.setText("Воспроизведение")
        elif state == "paused":
            self.player_status.setText("Пауза")
            self.save_current_progress(force=True)
        elif state == "ended":
            self.player_status.setText("Воспроизведение завершено")
            self.save_current_progress(force=True)
        elif state == "error":
            if self._quality_switch:
                self.rollback_quality_switch()
            else:
                self.player_status.setText("Не удалось воспроизвести поток.")
                self.show_player_overlay("Ошибка воспроизведения", 1200)
        self.update_play_pause_button()

    def rollback_quality_switch(self) -> None:
        switch = self._quality_switch
        if not switch:
            self._changing_quality = False
            return
        self._quality_switch = None
        old_url = str(switch.get("old_url") or "")
        if not old_url:
            self._changing_quality = False
            return
        self._pending_seek_ms = int(switch.get("position_ms", 0))
        self._pause_after_seek = not bool(switch.get("was_playing", True))
        self.set_quality_options(self._quality_options, old_url)
        self.show_player_overlay("Не удалось сменить качество", 1400)
        self.player_status.setText("Возвращаю прежнее качество…")
        self.start_direct_stream(old_url, quality_switch=True)

    def stop_video(self) -> None:
        self.save_current_progress(force=True)
        if self.vlc_player:
            self.vlc_player.stop()
        self.update_play_pause_button()
        self.position_slider.setValue(0)
        self.time_label.setText("00:00 / 00:00")

    def seek_video(self) -> None:
        if not self.vlc_player:
            return

        self.vlc_player.set_position(
            self.position_slider.value() / 1000.0
        )
        self.save_current_progress(force=True)

    def seek_relative(self, seconds: int) -> None:
        if not self.vlc_player:
            return
        current = self.vlc_player.get_time()
        duration = self.vlc_player.get_length()
        if current < 0 or duration <= 0:
            return
        new_time = max(0, min(duration, current + seconds * 1000))
        self.vlc_player.set_time(new_time)
        self.position_slider.setValue(int(new_time / duration * 1000))
        self.time_label.setText(
            f"{self.format_milliseconds(new_time)} / "
            f"{self.format_milliseconds(duration)}"
        )
        self.save_current_progress(force=True)
        self.show_player_overlay(f"{'+' if seconds > 0 else '−'}{abs(seconds)} сек")

    def show_player_overlay(self, text: str, timeout: int = 850) -> None:
        if not hasattr(self, "player_overlay"):
            return
        self.player_overlay.setText(text)
        self.player_overlay.adjustSize()
        self.position_player_overlays()
        self.player_overlay.show()
        self.player_overlay.raise_()
        self.overlay_hide_timer.start(timeout)

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
            self.update_play_pause_button()
            return

        self.update_play_pause_button()

        position = self.vlc_player.get_position()
        if position >= 0 and not self.position_slider.isSliderDown():
            self.position_slider.setValue(
                int(position * 1000)
            )

        current = self.vlc_player.get_time()
        duration = self.vlc_player.get_length()

        if self._pending_seek_ms > 0 and duration > 0:
            self.vlc_player.set_time(self._pending_seek_ms)
            self._pending_seek_ms = 0
            current = self.vlc_player.get_time()
            if self._pause_after_seek:
                self.vlc_player.set_pause(1)
                self._pause_after_seek = False
            if self._changing_quality:
                self._quality_switch = None
                self._changing_quality = False
                self.player_status.setText("Качество переключено")

        self.time_label.setText(
            f"{self.format_milliseconds(current)} / "
            f"{self.format_milliseconds(duration)}"
        )
        if time.monotonic() - self._last_history_save >= 4:
            self.save_current_progress()

    def toggle_fullscreen(self) -> None:
        if self._fullscreen_active or self.isFullScreen():
            self.exit_fullscreen()
        else:
            self.enter_fullscreen()

    def enter_fullscreen(self) -> None:
        if (
            self.stack.currentWidget() is not self.player_page
            or self._fullscreen_active
        ):
            return
        self._fullscreen_geometry = self.saveGeometry()
        self._fullscreen_was_maximized = self.isMaximized()
        self._fullscreen_visibility = {
            widget: widget.isVisible()
            for widget in (
                self.title_bar, self.player_top_bar, self.player_selectors,
                self.player_status, self.author_label,
            )
        }
        self._fullscreen_active = True
        self.showFullScreen()
        self.update_fullscreen_ui()
        self.show_fullscreen_controls()

    def exit_fullscreen(self) -> None:
        if not self._fullscreen_active and not self.isFullScreen():
            return
        self.save_current_progress(force=True)
        self._fullscreen_active = False
        self.controls_hide_timer.stop()
        self.unsetCursor()
        self.showNormal()
        if self._fullscreen_geometry is not None:
            self.restoreGeometry(self._fullscreen_geometry)
        if self._fullscreen_was_maximized:
            self.showMaximized()
        self.update_fullscreen_ui()

    def update_fullscreen_ui(self) -> None:
        fullscreen = self._fullscreen_active
        managed = (
            self.title_bar, self.player_top_bar, self.player_selectors,
            self.player_status, self.author_label,
        )
        for widget in managed:
            widget.setVisible(
                False if fullscreen else self._fullscreen_visibility.get(widget, True)
            )
        if fullscreen:
            self.player_root_layout.setContentsMargins(0, 0, 0, 0)
        else:
            self.player_root_layout.setContentsMargins(20, 16, 20, 20)
        self.player_root_layout.setSpacing(0 if fullscreen else 12)
        self.fullscreen_button.setText(
            "Выйти из полного экрана" if fullscreen else "Полный экран"
        )
        self.player_controls.show()
        self.video_frame.setStyleSheet(
            "background: #000; border: none; border-radius: 0;"
        )
        QTimer.singleShot(0, self.position_player_overlays)

    def show_fullscreen_controls(self) -> None:
        if not self._fullscreen_active:
            return
        was_hidden = not self.player_controls.isVisible()
        self.unsetCursor()
        self.player_controls.show()
        self.player_controls.raise_()
        self.position_player_overlays()
        self.controls_hide_timer.start()
        if was_hidden:
            debug_logger.debug("Controls shown")
        debug_logger.debug("Hide timer restarted")

    def hide_fullscreen_controls(self) -> None:
        if not self._fullscreen_active:
            return
        popup_visible = bool(
            self.quality_combo.view() and self.quality_combo.view().isVisible()
        )
        if (
            self.player_controls.underMouse()
            or self.position_slider.isSliderDown()
            or self.volume_slider.isSliderDown()
            or popup_visible
        ):
            self.controls_hide_timer.start()
            return
        self.player_controls.hide()
        self.setCursor(Qt.CursorShape.BlankCursor)
        debug_logger.debug("Fullscreen controls and cursor hidden")

    def position_player_overlays(self) -> None:
        if not hasattr(self, "player_surface"):
            return
        if self.player_overlay.isVisible():
            self.player_overlay.adjustSize()
            self.player_overlay.move(
                max(0, (self.player_surface.width() - self.player_overlay.width()) // 2),
                max(0, (self.player_surface.height() - self.player_overlay.height()) // 2),
            )

    def leave_player(self) -> None:
        self.save_current_progress(force=True)
        if self._fullscreen_active or self.isFullScreen():
            self.exit_fullscreen()
        self.stack.setCurrentWidget(self.details_page)

    def run_task(
        self,
        callback,
        on_success,
        on_error=None,
    ) -> None:
        thread = QThread(self)
        worker = Worker(callback)
        error_callback = on_error or self.on_task_failed
        handler = TaskResultHandler(on_success, error_callback)
        handler.setParent(self)
        worker.moveToThread(thread)

        self._threads.append(thread)
        self._workers.append(worker)
        self._task_handlers.append(handler)

        thread.started.connect(worker.run)
        worker.finished.connect(handler.handle_success)
        worker.finished.connect(thread.quit)
        worker.failed.connect(handler.handle_error)

        worker.failed.connect(thread.quit)
        worker.cancelled.connect(thread.quit)

        worker.finished.connect(worker.deleteLater)
        worker.failed.connect(worker.deleteLater)
        worker.cancelled.connect(worker.deleteLater)
        thread.finished.connect(thread.deleteLater)

        def cleanup() -> None:
            if worker in self._workers:
                self._workers.remove(worker)
            if thread in self._threads:
                self._threads.remove(thread)
            if handler in self._task_handlers:
                self._task_handlers.remove(handler)
            handler.deleteLater()

        thread.destroyed.connect(cleanup)
        thread.start()

    def on_task_failed(self, message: str) -> None:
        error_logger.error("Background task failed: %s", message)
        self.status_label.setText(message)
        QMessageBox.warning(self, APP_NAME, message)

    def load_catalog(self, media_type: str, force: bool = False) -> None:
        debug_logger.info("Catalog %s requested", media_type)
        if media_type not in self.catalog_cache:
            return
        self._catalog_media_type = media_type
        self.clear_history_button.setVisible(False)
        self.section_title.setText(
            "Популярные фильмы" if media_type == "movie" else "Популярные сериалы"
        )
        if self.catalog_loaded[media_type] and not force:
            items = self.catalog_cache[media_type]
            debug_logger.info("Cache hit: %s, %d items", media_type, len(items))
            debug_logger.info("Network request skipped")
            self.show_items(items)
            return
        if self.catalog_loading[media_type]:
            debug_logger.info("Catalog worker already running: %s", media_type)
            return
        debug_logger.info("Cache miss: %s; Starting worker", media_type)
        self.catalog_loading[media_type] = True
        self.status_label.setText("Загружаю каталог...")
        if not self.catalog_cache[media_type]:
            self.clear_cards()

        self._catalog_generation += 1
        generation = self._catalog_generation
        self.run_task(
            lambda: self.api.list_media(media_type, 1),
            lambda items: self._catalog_load_succeeded(media_type, items, generation),
            lambda message: self._catalog_load_failed(media_type, message, generation),
        )

    def refresh_catalog(self) -> None:
        media_type = getattr(self, "_catalog_media_type", "movie")
        self.load_catalog(media_type, force=True)

    def _catalog_load_succeeded(
        self, media_type: str, items: list[MediaItem], generation: int
    ) -> None:
        self.catalog_loading[media_type] = False
        self.catalog_cache[media_type] = list(items)
        self.catalog_loaded[media_type] = True
        if generation == self._catalog_generation:
            self.show_items(items)

    def _catalog_load_failed(
        self, media_type: str, message: str, generation: int
    ) -> None:
        self.catalog_loading[media_type] = False
        error_logger.error("Catalog %s failed: %s", media_type, message)
        if generation != self._catalog_generation:
            return
        cached = self.catalog_cache[media_type]
        if cached:
            self.show_items(cached)
            self.status_label.setText("Не удалось обновить каталог; показаны сохранённые данные.")
        else:
            self.catalog_loaded[media_type] = False
            self.status_label.setText("Не удалось загрузить каталог. Нажмите «Обновить каталог».")

    def search(self) -> None:
        query = self.search_input.text().strip()
        if not query:
            return

        self.clear_history_button.setVisible(False)

        self.section_title.setText(f"Поиск: {query}")
        self.status_label.setText("Ищу...")
        self.clear_cards()

        self._catalog_generation += 1
        generation = self._catalog_generation
        self.run_task(
            lambda: self.api.search(query, 1),
            lambda items: self.show_items(items)
            if generation == self._catalog_generation else None,
        )

    def clear_cards(self) -> None:
        self._media_cards_by_key.clear()
        while self.cards_layout.count():
            item = self.cards_layout.takeAt(0)
            widget = item.widget()
            if widget:
                widget.deleteLater()

    def show_items(self, items: list[MediaItem]) -> None:
        started = time.perf_counter()
        debug_logger.info("API/UI returned %d items; start show_items", len(items))
        self.current_items = items
        self.status_label.setText(
            f"Найдено: {len(items)}" if items else "Сервер не вернул карточки."
        )
        self.clear_cards()

        width = max(self.scroll.viewport().width(), 800)
        columns = max(1, width // (POSTER_WIDTH + 24))
        try:
            favorite_keys = self.database.get_favorite_keys()
        except Exception:
            favorite_keys = set()
            error_logger.exception("Cannot read favorite keys")

        created = 0
        for index, media in enumerate(items):
            try:
                card = MediaCard(
                    media,
                    (media.item_id, media.media_type) in favorite_keys,
                )
                card.clicked.connect(self.open_details)
                card.favorite_clicked.connect(self.toggle_favorite)
                self._media_cards_by_key.setdefault(
                    (media.item_id, media.media_type), []
                ).append(card)
                row, column = divmod(index, columns)
                self.cards_layout.addWidget(card, row, column)
                created += 1
            except Exception:
                error_logger.exception(
                    "Cannot create MediaCard id=%s type=%s",
                    media.item_id, media.media_type,
                )
        self.cards_host.update()
        debug_logger.info(
            "created %d cards; end show_items %.3fs",
            created, time.perf_counter() - started,
        )

    def toggle_favorite(self, item: MediaItem | None) -> None:
        if item is None or not item.item_id:
            return
        state = self.database.toggle_favorite(item)
        for card in self._media_cards_by_key.get(
            (item.item_id, item.media_type), []
        ):
            card.set_favorite(state)
        if (
            self.current_item is not None
            and self.current_item.item_id == item.item_id
            and self.current_item.media_type == item.media_type
        ):
            self.update_details_favorite_button()
        if self.section_title.text() == "Избранное" and not state:
            self.show_favorites()

    def update_details_favorite_button(self) -> None:
        item = self.current_item
        favorite = bool(
            item and self.database.is_favorite(item.item_id, item.media_type)
        )
        self.details_favorite_button.setText(
            "★ В избранном" if favorite else "☆ В избранное"
        )

    def save_current_progress(self, force: bool = False) -> None:
        if not self.vlc_player or not self._active_history:
            return
        current = self.vlc_player.get_time()
        duration = self.vlc_player.get_length()
        if current < 0:
            return
        context = self._active_history
        self.database.update_watch_progress(
            context["item"].item_id,
            context["item"].media_type,
            context["season"],
            context["episode"],
            current,
            duration,
        )
        self._last_history_save = time.monotonic()
        if duration > 0 and current / duration >= 0.90:
            self._active_history = None
            if self.section_title.text() == "История просмотра":
                self.show_history()

    def show_favorites(self) -> None:
        started = time.perf_counter()
        debug_logger.info("start load favorites")
        self._catalog_generation += 1
        self.clear_history_button.setVisible(False)
        self.section_title.setText("Избранное")
        self.show_items(self.database.get_favorites())
        debug_logger.info("end load favorites %.3fs", time.perf_counter() - started)

    def show_history(self) -> None:
        started = time.perf_counter()
        debug_logger.info("start load history")
        self._catalog_generation += 1
        self.section_title.setText("История просмотра")
        self.clear_history_button.setVisible(True)
        entries = self.database.get_history()
        self.clear_cards()
        self.current_items = []
        self.status_label.setText(
            f"Найдено: {len(entries)}" if entries else "История пуста."
        )
        width = max(self.scroll.viewport().width(), 800)
        columns = max(1, width // 420)
        for index, entry in enumerate(entries):
            card = HistoryCard(entry)
            card.continue_clicked.connect(self.continue_history)
            row, column = divmod(index, columns)
            self.cards_layout.addWidget(card, row, column)
        self.cards_host.update()
        debug_logger.info(
            "end load history entries=%d %.3fs",
            len(entries), time.perf_counter() - started,
        )

    def clear_history(self) -> None:
        self.database.clear_history()
        self.show_history()

    def open_details(self, item: MediaItem) -> None:
        self._details_generation += 1
        generation = self._details_generation
        self.current_item = item
        self.details_title.setText(item.title)
        self.details_meta.setText("Загружаю подробности...")
        self.details_overview.setText(item.overview or "Описание пока отсутствует.")
        self.details_poster.clear()
        self.details_poster.setText("Загрузка...")
        self.details_poster.load(item.poster_url)
        self.stack.setCurrentWidget(self.details_page)
        self.update_details_favorite_button()

        if not item.item_id:
            self.details_meta.setText("ID карточки отсутствует.")
            return

        self.run_task(
            lambda: self.api.details(item.media_type, item.item_id),
            lambda details: self.apply_details(details)
            if (
                generation == self._details_generation
                and self.current_item is not None
                and self.current_item.item_id == item.item_id
            ) else None,
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
        self.update_details_favorite_button()

    def show_message(self, text: str) -> None:
        QMessageBox.information(self, APP_NAME, text)

    def build_window_overlays(self) -> None:
        self.author_label = QLabel("By Zhernossek", self)
        self.author_label.setObjectName("authorLabel")
        self.author_label.setAttribute(
            Qt.WidgetAttribute.WA_TransparentForMouseEvents
        )
        self.author_label.adjustSize()
        self.setStyleSheet(
            self.styleSheet()
            + """
            QPushButton#favoriteStar {
                background: rgba(10, 10, 13, 205); border: 1px solid #555560;
                border-radius: 17px; padding: 0; color: #ffd54a; font-size: 21px;
            }
            QPushButton#favoriteStar:hover { background: #34343d; border-color: #ffd54a; }
            QPushButton#windowControl, QPushButton#windowClose {
                background: transparent; border: none; border-radius: 5px;
                padding: 0; font-size: 18px;
            }
            QPushButton#windowControl:hover { background: #35353e; }
            QPushButton#windowClose:hover { background: #d92332; color: white; }
            QPushButton#dangerButton { background: #421a20; border-color: #71303a; }
            QPushButton#dangerButton:hover { background: #69232e; }
            QLabel#authorLabel {
                background: transparent; color: #7d7d86;
                font-family: Consolas; font-size: 11px; border: none;
            }
            QFrame#historyCard {
                background: #15151a; border: 1px solid #2c2c34; border-radius: 12px;
            }
            QProgressBar { background: #303039; border: none; border-radius: 3px; height: 6px; }
            QProgressBar::chunk { background: #e50914; border-radius: 3px; }
            QWidget#customTitleBar { background: #0b0b0d; border-bottom: 1px solid #202027; }
            QLabel#titleBarName { color: #d5d5da; font-weight: 600; background: transparent; }
            """
        )
        self.resize_overlays()

    def resize_overlays(self) -> None:
        self.author_label.adjustSize()
        self.author_label.move(
            self.width() - self.author_label.width() - 15,
            self.height() - self.author_label.height() - 7,
        )
        self.author_label.raise_()
        self.position_player_overlays()

    def resizeEvent(self, event) -> None:
        super().resizeEvent(event)
        if hasattr(self, "author_label"):
            self.resize_overlays()

    def changeEvent(self, event) -> None:
        super().changeEvent(event)
        if event.type() == QEvent.Type.WindowStateChange:
            self.title_bar.update_maximize_icon()

    def nativeEvent(self, event_type, message):
        if (
            sys.platform.startswith("win")
            and event_type == b"windows_generic_MSG"
            and not self.isMaximized()
            and not self.isFullScreen()
        ):
            msg = ctypes.wintypes.MSG.from_address(int(message))
            if msg.message == 0x0084:
                x = ctypes.c_short(msg.lParam & 0xFFFF).value
                y = ctypes.c_short((msg.lParam >> 16) & 0xFFFF).value
                point = self.mapFromGlobal(QPoint(x, y))
                margin = 7
                left = point.x() <= margin
                right = point.x() >= self.width() - margin
                top = point.y() <= margin
                bottom = point.y() >= self.height() - margin
                if top and left:
                    return True, 13
                if top and right:
                    return True, 14
                if bottom and left:
                    return True, 16
                if bottom and right:
                    return True, 17
                if left:
                    return True, 10
                if right:
                    return True, 11
                if top:
                    return True, 12
                if bottom:
                    return True, 15
        return super().nativeEvent(event_type, message)

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
                border: none;
                border-radius: 0;
            }

            QWidget#playerSurface {
                background: #000000;
            }

            QWidget#playerControls {
                background: rgba(9, 9, 12, 220);
                border-top: 1px solid rgba(255, 255, 255, 28);
            }

            QLabel#playerOverlay {
                background: rgba(8, 8, 11, 210);
                color: white;
                border: 1px solid rgba(255, 255, 255, 35);
                border-radius: 10px;
                padding: 12px 18px;
                font-size: 18px;
                font-weight: 700;
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

            QPushButton#volumeButton,
            QPushButton#playPauseButton {
                min-width: 34px;
                max-width: 34px;
                min-height: 30px;
                padding: 2px;
                border-radius: 8px;
                font-size: 17px;
            }

            QWidget#volumeControls { background: transparent; }
            QLabel#volumeValue {
                background: transparent;
                color: #d5d5da;
                font-size: 12px;
            }
            QSlider#volumeSlider::groove:horizontal {
                height: 4px;
                background: #34343d;
                border-radius: 2px;
            }
            QSlider#volumeSlider::sub-page:horizontal {
                background: #d8d8dd;
                border-radius: 2px;
            }
            QSlider#volumeSlider::handle:horizontal {
                width: 12px;
                height: 12px;
                margin: -4px 0;
                background: #f4f4f6;
                border: 1px solid #8d8d96;
                border-radius: 6px;
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
        if self._closing:
            if any(thread.isRunning() for thread in self._threads):
                event.ignore()
                return
            event.accept()
            return

        self._closing = True

        app = QApplication.instance()
        if app is not None and hasattr(self, "input_controller"):
            app.removeEventFilter(self.input_controller)

        self.save_current_progress(force=True)

        if self.player_timer:
            self.player_timer.stop()

        if self.vlc_player:
            self.vlc_player.stop()

        if self.web_player is not None:
            self.web_player.setUrl(QUrl("about:blank"))

        active_threads = []
        for thread in list(self._threads):
            thread.requestInterruption()
            thread.quit()
            if thread.isRunning():
                active_threads.append(thread)

        if not active_threads:
            event.accept()
            return

        for thread in active_threads:
            thread.finished.connect(self._finish_close_when_ready)
        event.ignore()

    def _finish_close_when_ready(self) -> None:
        QTimer.singleShot(0, self.close)
