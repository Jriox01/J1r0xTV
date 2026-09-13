from PySide6.QtCore import Qt, QUrl, Signal
from PySide6.QtGui import QPixmap, QPixmapCache
from PySide6.QtNetwork import (
    QNetworkAccessManager, QNetworkDiskCache, QNetworkReply, QNetworkRequest,
)
from PySide6.QtWidgets import (
    QFrame, QHBoxLayout, QLabel, QProgressBar, QPushButton, QVBoxLayout,
    QWidget,
)

from .config import POSTER_HEIGHT, POSTER_WIDTH, get_app_data_dir
from .models import MediaItem


class CustomTitleBar(QWidget):
    def __init__(self, window) -> None:
        super().__init__(window)
        self.host_window = window
        self.setObjectName("customTitleBar")
        self.setFixedHeight(42)

        layout = QHBoxLayout(self)
        layout.setContentsMargins(14, 4, 8, 4)
        layout.setSpacing(2)
        title = QLabel("J1r0x TV")
        title.setObjectName("titleBarName")
        layout.addWidget(title)
        layout.addStretch(1)

        self.minimize_button = QPushButton("—")
        self.maximize_button = QPushButton("□")
        self.close_button = QPushButton("×")
        for button in (
            self.minimize_button, self.maximize_button, self.close_button
        ):
            button.setFixedSize(42, 34)
            button.setObjectName("windowControl")
        self.close_button.setObjectName("windowClose")
        self.minimize_button.clicked.connect(window.showMinimized)
        self.maximize_button.clicked.connect(self.toggle_maximized)
        self.close_button.clicked.connect(window.close)
        layout.addWidget(self.minimize_button)
        layout.addWidget(self.maximize_button)
        layout.addWidget(self.close_button)

    def toggle_maximized(self) -> None:
        if self.host_window.isMaximized():
            self.host_window.showNormal()
        else:
            self.host_window.showMaximized()
        self.update_maximize_icon()

    def update_maximize_icon(self) -> None:
        self.maximize_button.setText(
            "❐" if self.host_window.isMaximized() else "□"
        )

    def mousePressEvent(self, event) -> None:
        if (
            event.button() == Qt.MouseButton.LeftButton
            and self.host_window.windowHandle() is not None
        ):
            self.host_window.windowHandle().startSystemMove()
            event.accept()
            return
        super().mousePressEvent(event)

    def mouseDoubleClickEvent(self, event) -> None:
        if event.button() == Qt.MouseButton.LeftButton:
            self.toggle_maximized()
            event.accept()
            return
        super().mouseDoubleClickEvent(event)


class ImageLabel(QLabel):
    _shared_network: QNetworkAccessManager | None = None
    _disk_cache: QNetworkDiskCache | None = None

    def __init__(self, width: int, height: int) -> None:
        super().__init__()
        self.setFixedSize(width, height)
        self.setAlignment(Qt.AlignmentFlag.AlignCenter)
        self.setObjectName("poster")
        self.setText("Нет постера")
        self._reply: QNetworkReply | None = None
        self._cache_key = ""

    @classmethod
    def network_manager(cls) -> QNetworkAccessManager:
        if cls._shared_network is None:
            cls._shared_network = QNetworkAccessManager()
            cls._disk_cache = QNetworkDiskCache(cls._shared_network)
            cache_dir = get_app_data_dir() / "cache" / "posters"
            cache_dir.mkdir(parents=True, exist_ok=True)
            cls._disk_cache.setCacheDirectory(str(cache_dir))
            cls._disk_cache.setMaximumCacheSize(100 * 1024 * 1024)
            cls._shared_network.setCache(cls._disk_cache)
        return cls._shared_network

    def load(self, url: str) -> None:
        if not url:
            return

        self.stop_loading()
        self._cache_key = f"j1r0xtv:{self.width()}x{self.height()}:{url}"
        cached = QPixmapCache.find(self._cache_key)
        if cached is not None:
            self.setPixmap(cached)
            self.setText("")
            return
        request = QNetworkRequest(QUrl(url))
        request.setHeader(
            QNetworkRequest.KnownHeaders.UserAgentHeader,
            "Mozilla/5.0",
        )
        reply = self.network_manager().get(request)
        self._reply = reply
        reply.finished.connect(self._apply_loaded_image)

    def stop_loading(self) -> None:
        reply = self._reply
        self._reply = None
        if reply is not None:
            reply.abort()
            reply.deleteLater()

    def _apply_loaded_image(self) -> None:
        reply = self.sender()
        if not isinstance(reply, QNetworkReply):
            return

        if reply is not self._reply:
            reply.deleteLater()
            return

        self._reply = None
        if reply.error() == QNetworkReply.NetworkError.NoError:
            pixmap = QPixmap()
            if pixmap.loadFromData(bytes(reply.readAll())):
                scaled = pixmap.scaled(
                    self.size(),
                    Qt.AspectRatioMode.KeepAspectRatioByExpanding,
                    Qt.TransformationMode.SmoothTransformation,
                )
                self.setPixmap(scaled)
                if self._cache_key:
                    QPixmapCache.insert(self._cache_key, scaled)
                self.setText("")
        reply.deleteLater()


class MediaCard(QFrame):
    clicked = Signal(object)
    favorite_clicked = Signal(object)

    def __init__(self, item: MediaItem, is_favorite: bool = False) -> None:
        super().__init__()
        self.item = item
        self.setObjectName("mediaCard")
        self.setCursor(Qt.CursorShape.PointingHandCursor)
        self.setFixedWidth(POSTER_WIDTH)

        layout = QVBoxLayout(self)
        layout.setContentsMargins(0, 0, 0, 0)
        layout.setSpacing(8)

        poster_host = QFrame()
        poster_host.setFixedSize(POSTER_WIDTH, POSTER_HEIGHT)
        poster_host.setStyleSheet("background: transparent; border: none;")
        poster = ImageLabel(POSTER_WIDTH, POSTER_HEIGHT)
        poster.setParent(poster_host)
        poster.move(0, 0)
        poster.load(item.poster_url)

        self.favorite_button = QPushButton(poster_host)
        self.favorite_button.setObjectName("favoriteStar")
        self.favorite_button.setFixedSize(34, 34)
        self.favorite_button.move(POSTER_WIDTH - 42, 8)
        self.favorite_button.setCursor(Qt.CursorShape.PointingHandCursor)
        self.favorite_button.clicked.connect(
            lambda: self.favorite_clicked.emit(self.item)
        )
        self.set_favorite(is_favorite)
        self.favorite_button.raise_()

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

        layout.addWidget(poster_host)
        layout.addWidget(title)
        layout.addWidget(meta)

    def mousePressEvent(self, event) -> None:
        if event.button() == Qt.MouseButton.LeftButton:
            self.clicked.emit(self.item)
        super().mousePressEvent(event)

    def set_favorite(self, value: bool) -> None:
        self.favorite_button.setText("★" if value else "☆")
        self.favorite_button.setToolTip(
            "Удалить из избранного" if value else "Добавить в избранное"
        )


class HistoryCard(QFrame):
    continue_clicked = Signal(object)

    def __init__(self, entry: dict) -> None:
        super().__init__()
        self.entry = entry
        item = entry["item"]
        self.setObjectName("historyCard")
        self.setFixedWidth(390)

        root = QHBoxLayout(self)
        root.setContentsMargins(12, 12, 12, 12)
        root.setSpacing(14)

        poster = ImageLabel(100, 150)
        poster.load(item.poster_url)
        root.addWidget(poster)

        content = QVBoxLayout()
        title = QLabel(item.title)
        title.setObjectName("cardTitle")
        title.setWordWrap(True)
        content.addWidget(title)

        if item.media_type == "tv":
            detail = " • ".join(
                value for value in (
                    entry.get("season", ""), entry.get("episode", "")
                ) if value
            )
            if detail:
                series = QLabel(detail)
                series.setObjectName("cardMeta")
                content.addWidget(series)

        progress = max(0.0, min(float(entry.get("progress", 0)), 1.0))
        percent = QLabel(f"Просмотрено: {round(progress * 100)}%")
        percent.setObjectName("cardMeta")
        content.addWidget(percent)

        bar = QProgressBar()
        bar.setRange(0, 1000)
        bar.setValue(round(progress * 1000))
        bar.setTextVisible(False)
        content.addWidget(bar)

        position = int(entry.get("position_ms", 0))
        duration = int(entry.get("duration_ms", 0))
        timing = QLabel(
            f"{self._format_time(position)} / {self._format_time(duration)}"
        )
        timing.setObjectName("cardMeta")
        content.addWidget(timing)
        content.addStretch()

        button = QPushButton("Продолжить")
        button.setObjectName("primaryButton")
        button.clicked.connect(lambda: self.continue_clicked.emit(self.entry))
        content.addWidget(button)
        root.addLayout(content, 1)

    @staticmethod
    def _format_time(value: int) -> str:
        total = max(0, value) // 1000
        hours, remainder = divmod(total, 3600)
        minutes, seconds = divmod(remainder, 60)
        return (
            f"{hours:02}:{minutes:02}:{seconds:02}"
            if hours else f"{minutes:02}:{seconds:02}"
        )
