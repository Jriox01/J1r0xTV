"""Local-only direct-video fixture with Range/ETag, HTTP errors and a throttled body."""
import argparse
import http.server
import json
import re
import time
from pathlib import Path
from urllib.parse import urlsplit


def handler_for(video):
    class Handler(http.server.BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def do_HEAD(self):
            self.respond(head=True)

        def do_GET(self):
            self.respond(head=False)

        def respond(self, head):
            path = urlsplit(self.path).path
            if path == "/metadata":
                data = json.dumps({"size": video.stat().st_size}).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                if not head:
                    self.wfile.write(data)
                return
            if path == "/403.mp4":
                self.send_error(403)
                return
            if path == "/html.mp4":
                data = b"<html>This is not a video</html>"
                self.send_response(200)
                self.send_header("Content-Type", "text/html")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                if not head:
                    self.wfile.write(data)
                return
            if not path.endswith(".mp4"):
                self.send_error(404)
                return
            size = video.stat().st_size
            start, end = 0, size - 1
            requested = self.headers.get("Range")
            if requested:
                match = re.fullmatch(r"bytes=(\d+)-(\d*)", requested)
                if not match:
                    self.send_error(416)
                    return
                start = int(match[1])
                end = min(int(match[2]), size - 1) if match[2] else size - 1
                if start > end:
                    self.send_error(416)
                    return
            self.send_response(206 if requested else 200)
            self.send_header("Content-Type", "video/mp4")
            self.send_header("Content-Length", str(end - start + 1))
            self.send_header("Accept-Ranges", "bytes")
            self.send_header("ETag", '"jirox-download-fixture-v1"')
            self.send_header("Last-Modified", "Mon, 01 Jan 2024 00:00:00 GMT")
            if requested:
                self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
            self.end_headers()
            if head:
                return
            try:
                with video.open("rb") as stream:
                    stream.seek(start)
                    remaining = end - start + 1
                    while remaining:
                        chunk = stream.read(min(65536, remaining))
                        self.wfile.write(chunk)
                        self.wfile.flush()
                        remaining -= len(chunk)
                        time.sleep(0.08)
            except (BrokenPipeError, ConnectionResetError):
                pass
    return Handler


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("video", type=Path)
    parser.add_argument("--port", type=int, default=18766)
    args = parser.parse_args()
    if not args.video.is_file():
        parser.error("Generate a fixture with CreateDownloadFixture.swift first")
    server = http.server.ThreadingHTTPServer(("127.0.0.1", args.port), handler_for(args.video))
    print(f"Download fixture listening on {args.port}", flush=True)
    server.serve_forever()
