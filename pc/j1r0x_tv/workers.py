import requests
from PySide6.QtCore import QObject, QThread, Signal, Slot

from .api import SourceUnavailableError

class Worker(QObject):
    finished = Signal(object)
    failed = Signal(str)
    cancelled = Signal()

    def __init__(self, callback) -> None:
        super().__init__()
        self.callback = callback

    def run(self) -> None:
        thread = QThread.currentThread()
        if thread.isInterruptionRequested():
            self.cancelled.emit()
            return
        try:
            result = self.callback()
            if thread.isInterruptionRequested():
                self.cancelled.emit()
            else:
                self.finished.emit(result)
        except SourceUnavailableError as exc:
            self._emit_failure_or_cancel(str(exc), thread)

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

            self._emit_failure_or_cancel(message, thread)

        except requests.RequestException as exc:
            self._emit_failure_or_cancel(
                f"Ошибка подключения к серверу: {exc}", thread
            )
        except Exception as exc:
            self._emit_failure_or_cancel(f"Ошибка: {exc}", thread)

    def _emit_failure_or_cancel(self, message: str, thread: QThread) -> None:
        if thread.isInterruptionRequested():
            self.cancelled.emit()
        else:
            self.failed.emit(message)


class TaskResultHandler(QObject):
    def __init__(self, on_success, on_error) -> None:
        super().__init__()
        self.on_success = on_success
        self.on_error = on_error

    @Slot(object)
    def handle_success(self, result) -> None:
        self.on_success(result)

    @Slot(str)
    def handle_error(self, message: str) -> None:
        self.on_error(message)
