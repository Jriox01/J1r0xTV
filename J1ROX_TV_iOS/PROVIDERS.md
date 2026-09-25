# Video providers

`VideoProvider` defines identity lookup (TMDB or title/year), source discovery,
translations, seasons, episodes, logical candidate requests and fresh playback resolution.
`ProviderResolver` tries registered providers in order, validates each candidate and
advances after failures. Source-specific IDs are provider-owned; a new provider must
map the request media identity and translation name rather than reuse another provider's IDs.

Atodo retains the existing catalog/search/details endpoints, balancer discovery,
JSON/Base64 source resolution and playback headers. The Core Data schema is unchanged.
Playback URLs are not persisted. Resuming history repeats provider resolution.
Known `expires_at` and quality metadata are propagated; unknown values stay nil.

The detail screen discovers choices using the first available provider. AVPlayer
receives a provider-independent `PlaybackSource`; `PlayerSession` owns AVFoundation observations and accepts only PlaybackSource.
`PlaybackSession` handles recovery through ProviderResolver. A candidate is refreshed
at most twice during runtime recovery, then excluded for that session.
Selected episode/season and resume time survive fallback. Named translations must
match at the replacement source; a different episode is never silently substituted.

HLS validation uses HEAD and at most 1024 application-consumed bytes of GET, with
Range, a 6-second request timeout, an 8-second resource timeout and a 15-second
resolver operation deadline. It checks HTTP success, Content-Type and #EXTM3U.
It does not download media segments. A successful probe is not a guarantee of
future playback: AVPlayer failures still invoke recovery. Cookies are not collected
by the probe; headers are stripped on cross-origin redirects. General diagnostics redact
paths and query values. The explicitly requested DEBUG-only `[Player]` stream/probe/redirect
and failed-resource logs contain full URLs for on-device ATS investigation. They can
contain expiring signed query values; HTTP headers are not logged. Release omits these logs.

## Cinemap status (2026-09-14)

See [CINEMAP-RESEARCH.md](CINEMAP-RESEARCH.md) for reproducible network observations,
public-code findings and the missing integration contract.

Cinemap is unsupported. Repository search found no Cinemap/Kinogo integration.
Searches for official cinemap.cc API/embed documentation did not establish an
allowed integration, and the public site could not be retrieved in this environment.
Cinemapress/Kinobox and similarly named services are not evidence of Cinemap's API.
This is a research limitation, not a claim that no such API exists anywhere.

No Cinemap requests, captured cookies, token generation, protected-request parsing
or hardcoded temporary CDN URLs have been added. Enabling it requires verified
provider documentation/permission and a supported playback or embed contract.
An embed alone must not be treated as a direct AVPlayer stream.

References checked:
- https://cinemap.cc
- https://developer.apple.com/documentation/foundation/urlsession/bytes(for:delegate:)

## Regression checks

Run on macOS with Xcode command-line tools:

```bash
bash J1ROX_TV_iOS/Tests/run-provider-tests.sh
```

Both unsigned Codemagic workflows execute this before building the iOS app.
Fixtures cover movie lookup, title/year filtering, two translations, a series with
three episodes, missing episode rejection, bounded HLS probes, 4xx/5xx, invalid
Content-Type/playlist, expiry renewal, timeout, provider fallback and unsupported
Cinemap. They never request real third-party media. Live Atodo/iPhone playback
remains a separate manual integration check; fixture success must not be reported
as confirmation of real content availability.

## Debug playback and research tests

The DEBUG-only HLS Test tab accepts an explicitly supplied permitted URL and optional
headers. TestHLSProvider never joins the production provider list; a manual URL has
no refresh endpoint and returns refreshUnsupported. PlayerView only hosts the
PlayerSession AVPlayer. The explicit `refresh(source:request:)` provider capability
has a default unsupported implementation; Atodo reuses its existing fresh resolution.
Snapshots preserve time, play/pause and matching in-manifest audio/subtitle selections.
External subtitle URLs are metadata, not an implemented sidecar-subtitle renderer.

Arbitrary AVURLAssetHTTPHeaderFieldsKey headers retain the existing compatibility
path. Apple documents AVURLAssetHTTPUserAgentKey, but not a universal custom-header
contract. Child-segment/cross-origin header propagation is NOT GUARANTEED. Preflight
redirects strip credentials on origin changes and reject HTTPS downgrades. Production ATS
has one exact-host HTTP exception for the observed ATODO xinu CDN `ok26-1.vkuser.net`.
No global/media/web-content ATS bypass or subdomain wildcard is enabled; HTTPS trust/TLS
requirements remain unchanged. See [ATS-VERIFICATION.md](ATS-VERIFICATION.md) for evidence
and the limits of the Windows checks.

Tests/Research contains offline Kinogo/Cinemar fixture parsers, not a scraper or a
production provider. See Tests/Fixtures/README.md for provenance and missing snapshots.
Cinemap remains UNSUPPORTED pending a permitted fresh PlaybackSource interface.
The architecture report is ../CINEMAR-ARCHITECTURE.md.

ios-check now compiles Debug for Simulator, runs an explicit simulator smoke launch,
and compiles unsigned Release. Smoke tests use Apple's public Bip Bop test streams
and two locally AES-128-encrypted sample segments with a locally generated test key.
No protected content or third-party encryption key is used. Local-network permission
is added only to the built simulator app, not the source Info.plist or unsigned IPA.
The simulator reports readyToPlay, advancing time and paused resume to seven seconds;
logs/results are in build/logs/hls-smoke-results.json. External test CDN availability
can independently fail this integration step even when fixture unit tests pass.
The Release IPA deliberately has no Debug tab or automated smoke launch.
