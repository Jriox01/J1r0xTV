# Research fixtures

These files are local inputs only. Research parsers live under `Tests/Research`,
are compiled into the test executable, and are not part of the iOS application.
No test sends a Kinogo/Cinemar request or executes supplied JavaScript.

`kinogo_movie_kolobok.html` is a reduced, sanitized projection of the supplied
`C:\J1r0xTV\Текстовый документ.txt`. It retains the original canonical link,
JSON-LD, Cinemar `li[data-src]` and `iframe[src]`. Unrelated scripts/UI are removed.
The opaque URL suffix is replaced consistently by `REDACTED_OPAQUE_FIXTURE`;
the parser must preserve that value verbatim. Equality of the two HTML attributes
was also checked against the original before redaction. Source SHA-256 is in
`provenance.json`. This fixture tests extraction, not descriptor validity.

`playlist_load_response.json` is the provided response example, sanitized:
the playback URL is replaced with a non-routable `example.invalid` URL, the
download descriptor is redacted and the thumbnail path anonymized. Duration
6217 and empty subtitle are retained. This is a JSON/model test, never playback.

Unavailable snapshots are deliberately absent, not replaced with invented pages:

- `kinogo_search_kolobok.html`: the expected three results remain NOT TESTED.
- `kinogo_movie_second.html`: NOT TESTED until the saved second page is supplied.
- `cinemar_embed.html`: NOT TESTED; a truncated config in a report isn't an HTML snapshot.
- Series/seasons/episodes/translations: NOT TESTED for Cinemar.

The runner prints NOT TESTED for absent optional snapshots and FAIL for a supplied
snapshot that violates an assertion. Add saved, reviewed, sanitized snapshots with
these names to activate their existing tests. Do not copy cookies, authorization,
session secrets or active signed descriptors into Git.

Parser precedence: JSON-LD → li[data-src] → iframe[src]. All references are exposed
for conflict checking, so disagreement is not silently presented as agreement.
Origin case is normalized; opaque suffix/query are neither decoded nor recreated.
Kinogo ID and Cinemar vid are extracted independently from their respective paths.
Repeated parsing of one snapshot proves deterministic parsing, not URL lifetime.

The small HTML tokenizer supports the saved markup and JSON object literals in
`Cinemar({...})`; it isn't a browser or a general JavaScript parser. It never evals
functions, decrypts `file` or computes opaque data. Series can use the same page
discovery parser; season/episode/translation schemas need actual additional fixtures.
