# CDN VideoHub native HLS source

CDN VideoHub is registered after Atodo and Zona. Title/year/type are matched through the existing Zona metadata lookup to obtain the Kinopoisk ID; TMDB IDs are never used as Kinopoisk IDs. The source then reads the anonymous CDN VideoHub playlist and resolves a fresh HLS URL for each playback or renewal. No account, API token, subscription, embedded player or stream proxy is configured.

Translations expose only their own season/episode entries. A selected translation or episode that disappears produces an explicit unavailable error rather than playing another one. Signed media URLs are not cached or logged. Downloads are not enabled for this source. Normal HTTPS and playback validation remain enabled.

## Verification

The isolated `cdn-source-probe` workflow, commit 63ac725, tested Interstellar (Kinopoisk 258687) on a Codemagic Mac mini M2. The anonymous API returned Russian dubbing. HLS returned HTTP 200, `application/x-mpegURL`, a valid `#EXTM3U` signature and AVFoundation PLAYABLE. Full-HD MP4 returned a valid MP4 signature but AVFoundation UNPLAYABLE; the adapter therefore uses HLS only.

This is a live asset playability check, not decoded playback on a physical iPhone. Availability may vary by title, region and the source's current service. A single successful anonymous request does not establish contractual availability or future pricing. The metadata mapping depends on Zona's catalog API, but playback uses CDN VideoHub directly and does not invoke Zona's stream SDK. Regression fixtures cover different seasons with the same episode number and refusal to silently change the selected voice or episode. Live series playback remains unverified.
