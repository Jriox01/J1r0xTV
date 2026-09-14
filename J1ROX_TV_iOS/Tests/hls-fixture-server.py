"""CI only: Apple public Bip Bop samples + locally encrypted test segments.
No production content, captured tokens, cookies or third-party encryption keys.
"""
import functools
import http.server
import json
import os
from pathlib import Path
import subprocess
import urllib.request

root = Path('build/hls-fixtures').resolve()
root.mkdir(parents=True, exist_ok=True)
base = 'https://devstreaming-cdn.apple.com/videos/streaming/examples/img_bipbop_adv_example_ts/'
key = os.urandom(16)
(root / 'key.bin').write_bytes(key)
playlist = '#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:6\n#EXT-X-MEDIA-SEQUENCE:0\n#EXT-X-PLAYLIST-TYPE:VOD\n'
for index in range(2):
    with urllib.request.urlopen(base + f'v5/fileSequence{index}.ts', timeout=25) as response:
        sample = response.read(4_000_001)
    assert 0 < len(sample) <= 4_000_000
    encrypted = subprocess.run(['openssl', 'enc', '-aes-128-cbc', '-K', key.hex(), '-iv', f'{index:032x}'],
                               input=sample, stdout=subprocess.PIPE, check=True).stdout
    (root / f'segment{index}.ts').write_bytes(encrypted)
    playlist += f'#EXT-X-KEY:METHOD=AES-128,URI="key.bin",IV=0x{index:032x}\n#EXTINF:6.0,\nsegment{index}.ts\n'
(root / 'aes.m3u8').write_text(playlist + '#EXT-X-ENDLIST\n', encoding='utf-8')

class Handler(http.server.SimpleHTTPRequestHandler):
    extensions_map = {**http.server.SimpleHTTPRequestHandler.extensions_map, '.m3u8': 'application/vnd.apple.mpegurl', '.ts': 'video/mp2t'}
    def log_message(self, *args):
        print(self.command, self.path.split('?')[0], flush=True)
    def do_HEAD(self):
        if self.special(): return
        super().do_HEAD()
    def do_GET(self):
        if self.special(): return
        super().do_GET()
    def special(self):
        if self.path == '/redirect.m3u8':
            self.send_response(302)
            self.send_header('Location', base + 'master.m3u8')
            self.end_headers()
            return True
        if self.path in ['/403.m3u8', '/404.m3u8', '/410.m3u8']:
            self.send_error(int(self.path[1:4])); return True
        if self.path == '/html.m3u8':
            self.send_response(200); self.send_header('Content-Type', 'text/html'); self.end_headers()
            if self.command != 'HEAD': self.wfile.write(b'<html>not HLS</html>')
            return True
        return False

server = http.server.ThreadingHTTPServer(('127.0.0.1', 18765), functools.partial(Handler, directory=str(root)))
(root / 'ready.json').write_text(json.dumps({'port': 18765}), encoding='utf-8')
server.serve_forever()
