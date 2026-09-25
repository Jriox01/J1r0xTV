# ATS playback investigation — 2026-09-25

## Finding and scope

Production uses `J1ROXTV/Resources/Info.plist` for both Debug and Release. It previously
had no ATS exception. The existing ATODO parser accepts HTTP and HTTPS media URLs.
`StreamingService.resolveSelected` / `ProviderResolver` validate a URL through URLSession;
`PlayerSession.start()` then passes `source.url` unchanged to `AVURLAsset` and `AVPlayerItem`.
An HTTP URL can therefore fail ATS during preflight, before AVPlayer is created.

A live API check of movie TMDB 550 found source `xinu` (UI «№2») returning signed
`http://ok26-1.vkuser.net/?…` MP4 URLs for qualities 144–1080. The path is `/`, with no
`.mp4` extension. Under the previous plist these requests were not allowed by iOS ATS.
This is a confirmed incompatible URL/policy combination. The failing iPhone session's
URL/title/source was not supplied, so it cannot be asserted that this exact host caused
that particular reported failure.

The same signed HTTP resource and its HTTPS counterpart were probed with range requests
on Windows. Both returned HTTP 400. HTTPS certificate verification succeeded, but this
does **not** confirm successful HTTPS media delivery; signed URL validity can depend on
client/IP/expiry. No HTTP→HTTPS rewrite was introduced and no certificate checks disabled.
Removing the ATS block does not fix an expired/invalid signature or a server HTTP 400.

## HLS and redirects checked

| Resource | Result |
| --- | --- |
| ATODO API `api.atodo.fun` | HTTPS response received |
| `jator` / «№1» master on `cdn4509.kinolordfilm.com` | HTTPS 200, `#EXTM3U`; server labels it `text/html` |
| All four child playlists of that master | HTTPS 200, 1,670 segment references per playlist |
| All references in those child playlists | Resolved to HTTPS on the same CDN host |
| First, middle and last segments of the 1080 variant | HTTPS 206, `video/mp2t`, verified TLS |
| Redirects in these stream requests | None observed |
| Encryption key references in these playlists | None present |
| `xinu` / «№2» signed MP4 on `ok26-1.vkuser.net` | API advertises HTTP; HTTP and HTTPS probes both returned 400 |

These observations cover the sampled streams, not every title or future CDN response.
Other HLS playlists may contain absolute HTTP segment/playlist/key URLs or redirects;
the primary playlist's HTTPS scheme alone does not establish their safety. The existing
preflight checks only the first 1,024 bytes and is not a recursive HLS audit. No playlists,
keys or segments are rewritten by this change. Unknown HTTP hosts remain subject to ATS.

## Change

The only production exception is:

```xml
<key>NSAppTransportSecurity</key>
<dict>
    <key>NSExceptionDomains</key>
    <dict>
        <key>ok26-1.vkuser.net</key>
        <dict>
            <key>NSExceptionAllowsInsecureHTTPLoads</key>
            <true/>
        </dict>
    </dict>
</dict>
```

`NSIncludesSubdomains` is omitted (false by default). No exception is applied to
`vkuser.net`, other CDN shards, `api.atodo.fun` or `kinolordfilm.com`. No global
`NSAllowsArbitraryLoads`, `NSAllowsArbitraryLoadsForMedia` or web-content bypass is used.
TLS minimums, forward secrecy and certificate validation are unchanged.

DEBUG prints `[Player] Final stream URL: …` immediately before AVURLAsset creation.
The preflight URL and redirects also have DEBUG logs because ATS can fail before the
player starts. AVPlayer error-log URIs are printed as `[Player] Failed resource URL: …`
to help identify failing child playlists/segments/keys. These full-URL diagnostics are
absent from Release and may include expiring signatures in Debug.

The HLS simulator script now tolerates the existing ATS dictionary and adds its local
network permission only to the built simulator app. Source production Info.plist does
not permit local networking. Downloads use the same app ATS policy; their implementation
is unchanged. SharePlay, selectors, progress, countdown and swipe code are unchanged.

## Validation

Windows checks: XML parsing and comparison with the previous plist, exact-host exception
scope, no global bypass or TLS downgrade, Debug/Release Info.plist paths, Swift syntax
comparison with baseline, shell syntax, and git diff checks. Live HTTP/HTTPS results above
are curl network checks, not iOS ATS or AVPlayer runtime tests.

Xcode/IPA compilation and device playback were not run on Windows. After Codemagic builds
the IPA, retest the original failing title/source on the iPhone. If a different CDN shard
or HLS child URL fails, capture its DEBUG probe/final/failed-resource URL before extending
the domain exceptions. Do not add an unverified CDN-wide wildcard.

Apple references: [domain-specific ATS exceptions](https://developer.apple.com/documentation/bundleresources/information-property-list/nsapptransportsecurity/nsexceptiondomains),
[insecure HTTP exception behavior](https://developer.apple.com/documentation/bundleresources/information-property-list/nsexceptionallowsinsecurehttploads),
[identifying blocked connections](https://developer.apple.com/documentation/security/identifying-the-source-of-blocked-connections).
