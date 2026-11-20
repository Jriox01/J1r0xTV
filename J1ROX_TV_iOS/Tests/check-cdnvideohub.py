"""Anonymous source probe. Never logs signed media URLs or downloads a movie."""
import json, pathlib, subprocess, tempfile, urllib.request
BASE = 'https://plapi.cdnvideohub.com/api/v1/player/sv/'
def read(url, limit=512000):
    with urllib.request.urlopen(url, timeout=20) as response:
        return response.status, response.headers.get('Content-Type', ''), response.read(limit)
def error(exc):
    return {'type': type(exc).__name__, 'http_status': getattr(exc, 'code', None)}
report = {'provider': 'CDN VideoHub', 'account_used': False, 'checks': []}
try:
    _, _, body = read(BASE + 'playlist?pub=12&aggr=kp&id=258687')
    playlist = json.loads(body)
    report['matched_title'] = playlist.get('titleName')
    report['voices'] = [item.get('voiceType') for item in playlist.get('items', [])]
    video_id = playlist['items'][0]['vkId']
    _, _, body = read(BASE + 'video/' + video_id)
    sources = json.loads(body)['sources']
    swift = '''import Foundation
import AVFoundation
let input = FileHandle.standardInput.readDataToEndOfFile()
guard let text = String(data: input, encoding: .utf8), let url = URL(string: text) else { exit(2) }
let asset = AVURLAsset(url: url)
let done = DispatchSemaphore(value: 0)
asset.loadValuesAsynchronously(forKeys: ["playable"]) { done.signal() }
if done.wait(timeout: .now() + 30) == .timedOut { asset.cancelLoading(); print("TIMEOUT") }
else { var error: NSError?; let loaded = asset.statusOfValue(forKey: "playable", error: &error) == .loaded; print(loaded && asset.isPlayable ? "PLAYABLE" : "UNPLAYABLE") }
'''
    with tempfile.TemporaryDirectory() as folder:
        source = pathlib.Path(folder) / 'Probe.swift'
        binary = pathlib.Path(folder) / 'probe'
        source.write_text(swift)
        subprocess.run(['swiftc', str(source), '-o', str(binary)], check=True, capture_output=True)
        for name in ['hlsUrl', 'mpegFullHdUrl']:
            check = {'format': name}
            try:
                url = sources[name]
                if not url.startswith('https://'): raise ValueError('Unsupported scheme')
                request = urllib.request.Request(url, headers={'Range': 'bytes=0-4095'})
                status, content_type, body = read(request, 4096)
                signature = body.startswith(b'#EXTM3U') if name == 'hlsUrl' else body[4:8] == b'ftyp'
                check.update(http_status=status, content_type=content_type, signature_valid=signature)
                if signature:
                    probe = subprocess.run([str(binary)], input=url, text=True, capture_output=True, timeout=40)
                    check['avfoundation'] = probe.stdout.strip() if probe.stdout.strip() in ['PLAYABLE','UNPLAYABLE','TIMEOUT'] else 'ERROR'
            except Exception as exc: check['error'] = error(exc)
            report['checks'].append(check)
except Exception as exc: report['error'] = error(exc)
report['result'] = 'PASS' if any(c.get('avfoundation') == 'PLAYABLE' for c in report['checks']) else 'FAIL'
path = pathlib.Path('build/logs/cdnvideohub-probe.json')
path.parent.mkdir(parents=True, exist_ok=True)
path.write_text(json.dumps(report, ensure_ascii=False, indent=2))
print(path.read_text())
