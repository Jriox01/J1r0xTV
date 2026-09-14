# Cinemap integration investigation — 2026-09-14

## Decision

UNSUPPORTED. No verified stable/public/authorized interface was found for the
required identity → item → translation → season → episode → fresh playback URL chain.
`CinemapProvider.swift`, Atodo and the resolver implementation remain unchanged.
This does not prove that a private partner API or an unindexed public API does not exist.
It means there is insufficient evidence to implement one without guessing endpoints,
reusing captured media URLs or reverse-engineering protected requests.

## Direct observations

Requests used ordinary HTTPS with certificate verification, without cookies,
Authorization, fabricated Referer, client tokens or playback URL guesses.

| Check | Observed result | What it establishes |
| --- | --- | --- |
| Local DNS for `cinemap.cc` | getaddrinfo error 11001 | No usable address in this environment |
| Google public DNS A and AAAA for `cinemap.cc` | DNS Status 0, no answers for either type | NODATA, not proof of an unregistered domain or NXDOMAIN |
| `https://cinemap.cc/` | DNS resolution failed before HTTP | HTML and script references could not be retrieved |
| `https://cinemap.cc/robots.txt` | Same DNS failure | No sitemap/discovery links obtained |
| `pegasus.host.cinemap.cc` DNS | CNAME `pegasus.zerocdn.com`, IPv4 `176.58.38.3` | A media delivery host exists; this is not a catalog API |
| `https://pegasus.host.cinemap.cc/` | HTTP 401, `text/html; charset=utf-8` | Root URL is not an accessible public discovery interface; says nothing conclusive about authorization of individual media paths |
| `https://video.cinemap.cc/` | TLS verification failed: certificate expired | Public root could not be inspected securely; verification was not disabled |
| `https://v206.cinemap.cc/` | HTTP 410 | This public root is gone; no usable interface returned |

The browser search/open tool also could not retrieve the main domain. DNS queries:
- https://dns.google/resolve?name=cinemap.cc&type=A
- https://dns.google/resolve?name=cinemap.cc&type=AAAA
- https://dns.google/resolve?name=pegasus.host.cinemap.cc&type=A

DNS and HTTP results describe this check's time and network, not permanent service state.
No IP substitution, alternate-IP connection or TLS bypass was attempted.

## Public HTML/JS and documentation search

Searches: `cinemap.cc API embed`, `cinemap.cc documentation integration`,
`cinemap.cc tmdb`, quoted domain with iframe/github/API/player, and GitHub code search.
No official integration documentation, schema, public SDK, stable embed contract,
TMDB mapping, catalog identifiers or fresh-playback endpoint was identified.

Public examples inspected as source text (not executed):
- https://github.com/yagajanow004-debug/film.tm.github.io/blob/HEAD/filmtm/index.html
  contains four literal MP4 references to `uranium.cdn.cinemap.cc`.
- https://github.com/yagajanow004-debug/film.tm.github.io/blob/HEAD/filmtm/index.js
  contains a literal MP4 reference with a malformed URL scheme/host.
- https://github.com/IvanKhomka/pingwit_java_maven_course/blob/HEAD/src/main/resources/part30/KinoGo.html
  contains link tags for `v206.cinemap.cc` and `video.cinemap.cc`, not a usable iframe/API contract.

These third-party examples are not provider documentation or permission to integrate.
The media URLs were not requested, copied into the application or used as test fixtures.
No downloadable official Cinemap player script was discovered from the retrieved pages.
Unrelated Cinemapress/Kinobox/Cinemabox material was not treated as Cinemap documentation.

## Where the temporary URL appears

The user-provided example describes an HLS delivery URL on the Pegasus CDN, with a
path suffix shaped like `:YYYYMMDDHH` and an observed Referer of `https://cinemap.cc/`.
This locates the example at the final media delivery stage, after some upstream
item/source selection. It does NOT reveal the endpoint that issued the URL.

The issuing request, request parameters and authorization contract were not observed.
Therefore the exact issuance stage cannot be identified from current evidence.
The timestamp-looking suffix alone does not establish expiry time, timezone,
signature semantics or whether it is instead a version/cache key. The observed
Referer is not proof that setting that header grants permission or is sufficient.
The CDN root's HTTP 401 is not proof of DRM or of any particular token algorithm.
No expiry parser or token generator is justified by this example.

## Missing integration requirements

1. A provider-authorized base URL and documented public/partner API or embed contract.
2. Lookup and stable identity mapping from TMDB ID or title/year, including movie/TV type.
3. A schema and stable identifiers for translations, seasons and episodes.
4. An authorized operation issuing a fresh playable URL for the selected item/episode.
5. Defined expiry/refresh behavior, required headers and allowed native-player usage.
6. Authorized samples/test access covering a movie and a multi-episode series.

An embed contract may support a web player but does not by itself authorize or expose
a direct HLS URL for AVPlayer. In that case a separate playback presentation contract
would need to be agreed before changing the current PlaybackSource architecture.

## Tests and release decision

Regression tests assert that Cinemap search/sources/content/requests/playback throw
`ProviderError.unsupported`, and that the real AtodoProvider with fixture API responses
works in both registry orders `[Cinemap, Atodo]` and `[Atodo, Cinemap]`.
Existing fixture tests cover HLS validation, expiry, timeout and available-provider fallback.
These tests do not claim live Cinemap movie/series/translation support or successful
Atodo → Cinemap playback. That direction remains unavailable while Cinemap is unsupported.

Run the updated tests in `ios-check`. Do not run `ios-ipa` for this investigation:
the user made it conditional on Cinemap actually being connected. The previously
successful unsigned IPA is retained and must not be labelled as a new Cinemap build.
