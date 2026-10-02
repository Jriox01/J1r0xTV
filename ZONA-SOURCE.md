# Zona source in J1ROX TV

The TMDB catalog remains the app's catalog. Zona is a separate playback source.

- Match title, year and movie/series type via the site's `/search` endpoint. Ambiguous matches fail rather than playing an unrelated title. TMDB and Kinopoisk IDs are never interchanged.
- Load season/episode metadata through `https://msx.zona.ms/api/series/{slug}?season={number}`.
- A short-lived, nonpersistent WKWebView loads the site's published `https://kinoserial.online/loader.js` SDK and calls `createStreamsProvider` / `getStreams`. It does not render or play HTML video. No login credentials or application API keys are passed to it.
- Only direct HTTPS HLS/MP4 streams without a required JavaScript URL transformation are exposed to AVPlayer. DASH, trailers, HTTP streams and unsupported transformations are rejected.
- SDK-supplied headers are preserved. Every playback/renewal asks for fresh URLs. An explicitly selected voice that disappears is reported unavailable.
- Resolver has cancellation and bounded timeouts. SDK requests may be limited by network, region, CDN availability, or changes to the site's private interface.
- Source selections are routed to the owning provider; Atodo remains available independently.

## Validation

`Tests/run-provider-tests.sh` checks matching, episode keys, stream filtering, headers, routing and voice preservation in Debug and Release.

`Tests/run-zona-smoke.sh` launches the simulator Debug app with `--zona-smoke-test` and writes a live SDK/AVFoundation report to `build/logs/zona-smoke-results.json`. This network-dependent diagnostic does not turn a successful compile into a claim of successful live playback. It probes asset playability, not decoded playback on a real iPhone.

Release builds do not expose the diagnostic UI. Do not mark this source verified until the live report has been inspected. Series/SharePlay compatibility still needs real-device testing.
