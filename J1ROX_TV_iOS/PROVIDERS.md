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
receives a provider-independent `PlaybackSource`; `PlaybackSession` handles item
failure/end-failure notifications, fresh resolution and bounded fallback. A candidate
is renewed at most once during runtime recovery, then excluded for that session.
Selected episode/season and resume time survive fallback. Named translations must
match at the replacement source; a different episode is never silently substituted.

HLS validation uses HEAD and at most 1024 application-consumed bytes of GET, with
Range, a 6-second request timeout, an 8-second resource timeout and a 15-second
resolver operation deadline. It checks HTTP success, Content-Type and #EXTM3U.
It does not download media segments. A successful probe is not a guarantee of
future playback: AVPlayer failures still invoke recovery. Cookies are not collected
by the probe; headers are stripped on cross-origin redirects. DEBUG logs contain
provider name and hostname only, never full playback URLs or HTTP credentials.

## Cinemap status (2026-09-14)

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
