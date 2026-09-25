"""Read-only live HTTP/HLS probe. Does not decode video or bypass TLS/CORS.

Requires Python 3 and curl (included in Windows). Output contains endpoints but no signed URLs.
"""
import argparse
import base64
import json
import pathlib
import re
import subprocess
import tempfile
from datetime import datetime, timezone
from urllib.parse import urlencode, urljoin, urlsplit


def endpoint(url):
    parsed = urlsplit(url)
    return parsed.scheme + "://" + parsed.netloc


def fetch(url, binary=False):
    with tempfile.TemporaryDirectory(prefix="j1rox-tizen-audit-") as directory:
        body, headers = pathlib.Path(directory) / "body", pathlib.Path(directory) / "headers"
        command = ["curl", "-sS", "-L", "--max-redirs", "5", "--max-time", "25",
                   "--max-filesize", "2097152", "-H", "Origin: null", "-D", str(headers),
                   "-o", str(body), "-w", "%{json}"]
        if binary:
            command += ["--range", "0-1023"]
        result = subprocess.run(command + [url], capture_output=True, text=True, encoding="utf-8")
        try:
            metadata = json.loads(result.stdout)
        except ValueError:
            metadata = {}
        header_text = headers.read_text(encoding="utf-8", errors="replace") if headers.exists() else ""
        cors = re.findall(r"(?im)^access-control-allow-origin:\s*(.+)$", header_text)
        content = body.read_bytes() if body.exists() else b""
        summary = {"endpoint": endpoint(url), "final_endpoint": endpoint(metadata.get("url_effective", url)),
                   "status": metadata.get("http_code", 0), "redirects": metadata.get("num_redirects", 0),
                   "tls_verify_result": metadata.get("ssl_verify_result"), "content_type": metadata.get("content_type"),
                   "cors": cors[-1].strip() if cors else None, "bytes": len(content), "curl_exit": result.returncode}
        # Do not return stderr/url_effective in reports: they can contain credentials in CDN queries.
        return content, summary, metadata.get("url_effective", url)


def api(path, params=None):
    url = "https://api.atodo.fun/" + path + ("?" + urlencode(params) if params else "")
    body, summary, _ = fetch(url)
    if summary["status"] != 200:
        raise RuntimeError("API " + path + ": HTTP " + str(summary["status"]))
    return json.loads(body), summary


def unwrap(value):
    for key in ("data", "result", "item", "movie"):
        if isinstance(value.get(key), dict):
            return value[key]
    return value


def values(value):
    return list(value.values()) if isinstance(value, dict) else value or []


def canonical(item, media_type):
    data = {"id": item["id"], "title": item.get("title") or item.get("name"),
            "original_title": item.get("original_title") or item.get("original_name"),
            "original_language": item.get("original_language"),
            "imdb_id": item.get("imdb_id") or item.get("external_ids", {}).get("imdb_id"),
            "year": (item.get("first_air_date") or item.get("release_date") or "")[:4], "type": media_type}
    return {k: v for k, v in data.items() if v is not None and v != ""}


def resolve(source, leaf):
    if "streams" in leaf:
        return leaf
    if not isinstance(leaf.get("data"), dict):
        return leaf
    encoded = base64.b64encode(json.dumps(leaf["data"], ensure_ascii=False).encode("utf-8")).decode("ascii")
    result, _ = api("api/source/" + source, {"data": encoded})
    return unwrap(result)


def playlist(url, depth=0, visited=None):
    visited = visited if visited is not None else set()
    if url in visited or depth > 3:
        return {"endpoint": endpoint(url), "skipped": "cycle/depth limit"}
    visited.add(url)
    body, summary, effective = fetch(url)
    text = body.decode("utf-8", errors="replace")
    summary["is_m3u8"] = text.lstrip().startswith("#EXTM3U")
    if not summary["is_m3u8"]:
        return summary
    variants, segments, keys, maps = [], [], [], []
    expects_variant = False
    for line in text.splitlines():
        line = line.strip()
        if line.startswith("#EXT-X-STREAM-INF:"):
            expects_variant = True
        elif line and not line.startswith("#"):
            (variants if expects_variant else segments).append(urljoin(effective, line))
            expects_variant = False
        elif line.startswith(("#EXT-X-KEY:", "#EXT-X-SESSION-KEY:", "#EXT-X-MAP:", "#EXT-X-MEDIA:", "#EXT-X-I-FRAME-STREAM-INF:")):
            match = re.search(r'URI="([^"]+)"', line)
            if match:
                reference = urljoin(effective, match.group(1))
                if "KEY:" in line:
                    keys.append(reference)
                elif line.startswith("#EXT-X-MAP:"):
                    maps.append(reference)
                else:
                    variants.append(reference)
    all_urls = variants + segments + keys + maps
    summary.update({"variants": len(variants), "segments": len(segments), "keys": len(keys), "maps": len(maps),
                    "referenced_endpoints": sorted(set(endpoint(u) for u in all_urls)),
                    "http_references": sum(u.startswith("http:") for u in all_urls),
                    "codecs": re.findall(r'CODECS="([^"]+)"', text)})
    summary["children"] = [playlist(child, depth + 1, visited) for child in variants[:6]]
    samples = list(dict.fromkeys(([segments[0], segments[len(segments) // 2], segments[-1]] if segments else []) + keys[:2] + maps[:2]))
    summary["resource_samples"] = [fetch(sample, binary=True)[1] for sample in samples if sample.startswith(("http://", "https://"))]
    return summary


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", default=".build/network-audit.json")
    args = parser.parse_args()
    report = {"time_utc": datetime.now(timezone.utc).isoformat(), "origin": "null", "samples": []}
    for media_type, media_id in (("movie", "550"), ("tv", "1399")):
        item, info = api("api/details/" + media_type + "/" + media_id)
        item = unwrap(item)
        params = canonical(item, media_type)
        sources, _ = api("api/source/list", params)
        for source in unwrap(sources).get("balancers", [])[:2]:
            sample = {"type": media_type, "id": media_id, "source": source["id"], "api": info}
            report["samples"].append(sample)
            try:
                payload, _ = api("api/source/" + source["id"], params)
                payload = unwrap(payload)
                translations = values(payload.get("translations"))
                sample["voices"] = len(translations)
                leaf = translations[0] if translations else payload
                if media_type == "tv":
                    seasons = values(leaf.get("seasons"))
                    sample["seasons"] = len(seasons)
                    episodes = values(seasons[0].get("episodes")) if seasons else []
                    sample["episodes_first_season"] = len(episodes)
                    if not episodes:
                        raise RuntimeError("No episode available")
                    leaf = episodes[0]
                resolved = resolve(source["id"], leaf)
                video = resolved.get("streams", {}).get("video", {})
                hls = video.get("hls", {}).get("master")
                direct = video.get("http", {})
                mp4 = direct.get("master") or next(iter(direct.get("qualities", {}).values()), None)
                if hls:
                    sample["hls"] = playlist(hls)
                elif mp4:
                    sample["direct"] = fetch(mp4, binary=True)[1]
                else:
                    sample["error"] = "No structured stream URL in sampled response"
            except (RuntimeError, ValueError, KeyError, IndexError) as error:
                sample["error"] = str(error)
            print(json.dumps({k: v for k, v in sample.items() if k not in ("hls", "api")}, ensure_ascii=False), flush=True)
    output = pathlib.Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    print("Report:", output.resolve())


if __name__ == "__main__":
    main()
