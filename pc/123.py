import sys

from PySide6.QtWidgets import QApplication

from j1r0x_tv.config import APP_NAME
from j1r0x_tv.window import MainWindow


def main() -> None:
    app = QApplication(sys.argv)
    app.setApplicationName(APP_NAME)

    window = MainWindow()
    window.show()

    sys.exit(app.exec())


if __name__ == "__main__":
    main()
