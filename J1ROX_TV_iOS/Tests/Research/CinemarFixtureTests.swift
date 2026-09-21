import Foundation

enum CinemarFixtureTests {
    private struct Failure: Error { let message: String }
    private static func require(_ value: Bool, _ message: String) throws {
        if !value { throw Failure(message: message) }
    }
    private static func fixture(_ name: String) throws -> String? {
        let url = URL(fileURLWithPath: "Tests/Fixtures").appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try String(contentsOf: url, encoding: .utf8)
    }
    static func run() throws {
        let base = URL(string: "https://kinogo.parts/filmy/115026-posledniy-bogatyr-kolobok.html")!
        if let html = try fixture("kinogo_search_kolobok.html") {
            let result = CinemarFixtureParser.search(html, base: base)
            try require(result.count == 3, "Expected 3 results in saved search snapshot")
            guard let kolobok = result.first(where: { $0.contentID == "115026" }) else { throw Failure(message: "Kolobok missing") }
            try require(kolobok.title == "Последний богатырь. Колобок (2026)", "Search title")
            try require(kolobok.pageURL == base && kolobok.category == "filmy" && kolobok.year == 2026, "Search identity/category/year")
            print("PASS Search HTML parsing; Search result extraction (three results); Kinogo content ID extraction")
        } else { print("NOT TESTED Search HTML parsing; Search result extraction: kinogo_search_kolobok.html missing") }

        guard let movie = try fixture("kinogo_movie_kolobok.html") else { throw Failure(message: "Required supplied movie fixture missing") }
        let references = CinemarFixtureParser.embeds(movie, base: base)
        try require(Set(references.map(\.sourceLocation.rawValue)) == ["jsonLD", "dataSrc", "iframe"], "All three embed locations")
        try require(Set(references.map { $0.url.absoluteString }).count == 1, "Embed URLs agree across locations")
        guard let preferred = CinemarFixtureParser.preferredEmbed(movie, base: base) else { throw Failure(message: "No embed") }
        try require(preferred.sourceLocation == .jsonLD, "JSON-LD priority")
        try require(preferred.url.host == "cinemar.cc" && preferred.url.path.contains("/embed/117074/") && preferred.providerContentID == "117074", "Cinemar identity")
        let id = CinemarFixtureParser.pageIdentity(base.absoluteString, base: base)?.id
        try require(id == "115026" && id != preferred.providerContentID, "Independent ID namespaces")
        let noJSON = movie.replacingOccurrences(of: #"<script\b[\s\S]*?</script\s*>"#, with: "", options: .regularExpression)
        try require(CinemarFixtureParser.preferredEmbed(noJSON, base: base)?.sourceLocation == .dataSrc, "data-src fallback")
        let iframeOnly = noJSON.replacingOccurrences(of: #"<li\b[\s\S]*?</li\s*>"#, with: "", options: .regularExpression)
        try require(CinemarFixtureParser.preferredEmbed(iframeOnly, base: base)?.sourceLocation == .iframe, "iframe fallback")
        let a = EmbedReference(url: preferred.url, discoveredAt: Date())
        let b = EmbedReference(url: CinemarFixtureParser.preferredEmbed(movie, base: base)!.url, discoveredAt: Date(timeIntervalSinceNow: 60))
        try require(a.url == b.url && a.discoveredAt != b.discoveredAt, "Same snapshot stable canonical URL; no lifetime inferred")
        let expectedSuffix = "REDACTED_OPAQUE_FIXTURE"
        try require(preferred.url.absoluteString.hasSuffix(expectedSuffix), "Opaque fixture suffix preserved verbatim")
        print("PASS Kinogo content ID extraction; Cinemar embed extraction; Cinemar vid extraction; JSON-LD/data-src/iframe cross-check and fallback; independent namespaces; repeated-fixture stability")

        if let second = try fixture("kinogo_movie_second.html") {
            guard let ref = CinemarFixtureParser.preferredEmbed(second, base: base) else { throw Failure(message: "Second movie embed missing") }
            try require(ref.providerContentID != preferred.providerContentID, "Second movie must have separate vid")
            try require(ref.url.path.hasPrefix("/embed/") && ref.url.pathComponents.count >= 4, "Second movie format")
            print("PASS Second movie embed format")
        } else { print("NOT TESTED Second movie: kinogo_movie_second.html missing") }

        if let embed = try fixture("cinemar_embed.html") {
            guard let config = CinemarFixtureParser.configuration(embed) else { throw Failure(message: "Cinemar JSON configuration not found") }
            try require(config.vid == 117074 && config.host == "kinogo.parts", "Embed configuration")
            try require(config.file != nil && config.cuid != nil && config.ssid != nil, "Expected public config fields")
            print("PASS Cinemar config parsing (opaque strings retained only)")
        } else { print("NOT TESTED Cinemar config parsing: cinemar_embed.html missing") }

        guard let response = try fixture("playlist_load_response.json") else { throw Failure(message: "Response snapshot missing") }
        let data = Data(response.utf8)
        let decoded = try JSONDecoder().decode(CinemarPlaylistResponse.self, from: data)
        try require(decoded.file.scheme == "https" && decoded.duration == 6217, "Response URL/duration")
        try require(decoded.thumbnails?.hasSuffix(".vtt") == true && decoded.subtitle == "" && decoded.download != nil, "Response auxiliary fields")
        var extended = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        extended["futureField"] = ["arbitrary": true]
        let future = try JSONDecoder().decode(CinemarPlaylistResponse.self, from: JSONSerialization.data(withJSONObject: extended))
        try require(future.file == decoded.file, "Unknown response fields ignored")
        let request = PlaybackRequest(media: MediaItem.parse(["id": .string("115026")]))
        let source = try decoded.playback(request: request, headers: ["User-Agent": "Fixture"])
        try require(source.url == decoded.file && source.headers["User-Agent"] == "Fixture" && source.duration == 6217 && source.expiresAt == nil && source.subtitles.isEmpty, "PlaybackSource mapping")
        let track = SubtitleTrack(id: "en", name: "English", language: "en", url: URL(string: "https://example.invalid/test.vtt")!)
        let withTrack = try decoded.playback(request: request, subtitles: [track])
        try require(withTrack.subtitles.first?.id == "en", "Explicit subtitle metadata mapping")
        // Cinemap now requires an API URL in both DEBUG and Release; no network request is made here.
        let configured = CinemapProvider(baseURL: URL(string: "https://fixture.invalid/video")!)
        try require(configured.availability == .available, "Configured Cinemap must be available")
        print("PASS Playlist response decoding; unknown fields; PlaybackSource mapping; configured Cinemap available")
        print("NOT TESTED Cinemar series / seasons / episodes / translations: saved fixtures missing")
    }
}
