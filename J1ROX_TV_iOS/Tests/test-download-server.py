"""Verifies the HTTP fixture used by the native iOS lifecycle test, on any platform."""
import importlib.util
import json
from pathlib import Path
import tempfile
import threading
import unittest
import urllib.error
import urllib.request
from http.server import ThreadingHTTPServer

spec = importlib.util.spec_from_file_location("download_fixture", Path(__file__).with_name("download-fixture-server.py"))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class DownloadFixtureTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.directory = tempfile.TemporaryDirectory()
        video = Path(cls.directory.name) / "fixture.mp4"
        cls.content = b"\x00\x00\x00\x18ftypisom" + bytes(range(256)) * 4
        video.write_bytes(cls.content)
        cls.server = ThreadingHTTPServer(("127.0.0.1", 0), module.handler_for(video))
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()
        cls.base = f"http://127.0.0.1:{cls.server.server_port}"

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()
        cls.thread.join()
        cls.directory.cleanup()

    def request(self, path, **kwargs):
        return urllib.request.urlopen(urllib.request.Request(self.base + path, **kwargs), timeout=5)

    def test_full_file_and_head(self):
        with self.request("/movie.mp4") as response:
            self.assertEqual(response.status, 200)
            self.assertEqual(response.read(), self.content)
            self.assertEqual(response.headers["Accept-Ranges"], "bytes")
        with self.request("/movie.mp4", method="HEAD") as response:
            self.assertEqual(int(response.headers["Content-Length"]), len(self.content))
            self.assertEqual(response.read(), b"")

    def test_resume_range_and_validator(self):
        with self.request("/movie.mp4", headers={"Range": "bytes=150-"}) as response:
            self.assertEqual(response.status, 206)
            self.assertEqual(response.read(), self.content[150:])
            self.assertEqual(response.headers["Content-Range"], f"bytes 150-{len(self.content)-1}/{len(self.content)}")
            self.assertEqual(response.headers["ETag"], '"jirox-download-fixture-v1"')

    def test_denied_and_bad_ranges(self):
        for path, headers, code in [("/403.mp4", {}, 403), ("/movie.mp4", {"Range": "bytes=99999-"}, 416),
                                    ("/movie.mp4", {"Range": "bytes=invalid"}, 416)]:
            with self.assertRaises(urllib.error.HTTPError) as error:
                self.request(path, headers=headers)
            self.assertEqual(error.exception.code, code)
            error.exception.close()

    def test_html_and_metadata(self):
        with self.request("/html.mp4") as response:
            self.assertEqual(response.headers["Content-Type"], "text/html")
        with self.request("/metadata") as response:
            self.assertEqual(json.load(response)["size"], len(self.content))


if __name__ == "__main__":
    unittest.main()
