import Foundation

// Research-only parsers: no URLSession, WebView, JavaScript execution or provider registration.
struct ContentSearchResult {
    let title: String
    let pageURL: URL
    let contentID: String
    let category: String
    let year: Int?
    let posterURL: URL?
}
enum EmbedLocation: String { case jsonLD, dataSrc, iframe }
struct EmbeddedReference {
    let url: URL
    let providerContentID: String
    let sourceLocation: EmbedLocation
    var provider: String { "Cinemar" }
}
struct EmbedReference {
    let url: URL
    let discoveredAt: Date
    // Lifetime unknown; no inferred expiresAt.
}
struct CinemarConfiguration: Decodable {
    let vid: Int
    let cuid: String?
    let ssid: String?
    let host: String?
    let poster: String?
    let file: String? // Opaque; never decoded or generated here.
}
struct CinemarPlaylistResponse: Decodable {
    let file: URL
    let duration: Double?
    let thumbnails: String?
    let download: String?
    let subtitle: String?

    func playback(request: PlaybackRequest, headers: [String: String] = [:],
                  expiresAt: Date? = nil, subtitles: [SubtitleTrack] = []) throws -> PlaybackSource {
        guard ["https", "http"].contains(file.scheme), file.host != nil else { throw PlaybackError.invalidURL }
        return .init(request: request, url: file, providerID: "cinemap", providerName: "Cinemap",
                     headers: headers, expiresAt: expiresAt, subtitles: subtitles, duration: duration)
    }
}

enum CinemarFixtureParser {
    static func search(_ html: String, base: URL) -> [ContentSearchResult] {
        let tree = HTMLNode.parse(html)
        return tree.descendants.filter { $0.tag == "article" && $0.attributes["class", default: ""].split(separator: " ").contains("shortStory") }.compactMap { article in
            let links = article.descendants.filter { $0.tag == "a" }
            let link = links.first { $0.parent?.tag == "h2" || $0.parent?.tag == "h3" }
                ?? links.first { pageIdentity($0.attributes["href", default: ""], base: base) != nil }
            guard let link, let identity = pageIdentity(link.attributes["href", default: ""], base: base) else { return nil }
            let title = link.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return nil }
            let year = capture(#"\b((?:19|20)\d{2})\b"#, title).flatMap(Int.init)
            let image = article.descendants.first { $0.tag == "img" }
            let poster = (image?.attributes["data-src"] ?? image?.attributes["src"]).flatMap { URL(string: $0, relativeTo: base)?.absoluteURL }
            return .init(title: title, pageURL: identity.url, contentID: identity.id, category: identity.category, year: year, posterURL: poster)
        }
    }

    static func pageIdentity(_ raw: String, base: URL) -> (url: URL, id: String, category: String)? {
        guard let url = URL(string: raw, relativeTo: base)?.absoluteURL,
              ["http", "https"].contains(url.scheme), url.host == base.host,
              let match = matches(#"^/(filmy|serialy|anime)/(\d+)-[^/]+\.html$"#, url.path).first else { return nil }
        return (url, match[2], match[1])
    }

    /// Priority: JSON-LD, li[data-src], iframe[src]. Conflicting references are retained.
    static func embeds(_ html: String, base: URL) -> [EmbeddedReference] {
        let tree = HTMLNode.parse(html)
        var result: [EmbeddedReference] = []
        for script in tree.descendants where script.tag == "script" && script.attributes["type"]?.lowercased() == "application/ld+json" {
            if let object = try? JSONSerialization.jsonObject(with: Data(script.rawText.utf8)) {
                for value in embedStrings(object) {
                    if let ref = embed(value, base: base, location: .jsonLD) { result.append(ref) }
                }
            }
        }
        for (tag, attribute, location) in [("li", "data-src", EmbedLocation.dataSrc), ("iframe", "src", .iframe)] {
            for node in tree.descendants where node.tag == tag {
                if let raw = node.attributes[attribute], let ref = embed(raw, base: base, location: location) { result.append(ref) }
            }
        }
        return result
    }
    static func preferredEmbed(_ html: String, base: URL) -> EmbeddedReference? { embeds(html, base: base).first }

    private static func embed(_ raw: String, base: URL, location: EmbedLocation) -> EmbeddedReference? {
        guard !raw.contains(where: { $0.isWhitespace }),
              let url = URL(string: raw, relativeTo: base)?.absoluteURL,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: true),
              ["https", "http"].contains(components.scheme?.lowercased()),
              ["cinemar.cc", "cinemap.cc"].contains(components.host?.lowercased()),
              components.user == nil, components.password == nil,
              let id = capture(#"^/embed/(\d+)/.+$"#, components.percentEncodedPath) else { return nil }
        // Normalize origin only. Preserve percent-encoded suffix, query and fragment.
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        guard let canonical = components.url else { return nil }
        return .init(url: canonical, providerContentID: id, sourceLocation: location)
    }
    private static func embedStrings(_ value: Any) -> [String] {
        if let list = value as? [Any] { return list.flatMap(embedStrings) }
        guard let object = value as? [String: Any] else { return [] }
        return (object["embedUrl"] as? String).map { [$0] } ?? object.values.flatMap(embedStrings)
    }

    /// Accepts JSON object literals only; never evals JavaScript or decodes opaque fields.
    static func configuration(_ html: String) -> CinemarConfiguration? {
        for node in HTMLNode.parse(html).descendants where node.tag == "script" {
            let text = node.rawText
            guard let call = text.range(of: #"\bCinemar\s*\(\s*\{"#, options: .regularExpression),
                  let start = text[call].lastIndex(of: "{") else { continue }
            var depth = 0; var quoted = false; var escaped = false
            for index in text[start...].indices {
                let ch = text[index]
                if quoted {
                    if escaped { escaped = false }
                    else if ch == "\\" { escaped = true }
                    else if ch == "\"" { quoted = false }
                } else if ch == "\"" { quoted = true }
                else if ch == "{" { depth += 1 }
                else if ch == "}" {
                    depth -= 1
                    if depth == 0 { return try? JSONDecoder().decode(CinemarConfiguration.self, from: Data(text[start...index].utf8)) }
                }
            }
        }
        return nil
    }
    fileprivate static func matches(_ pattern: String, _ text: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { match in
            (0..<match.numberOfRanges).map { Range(match.range(at: $0), in: text).map { String(text[$0]) } ?? "" }
        }
    }
    private static func capture(_ pattern: String, _ text: String) -> String? { matches(pattern, text).first?[1] }
}

/// Small fixture DOM tokenizer, not a browser. Supports the saved markup's quoted
/// attributes, raw script JSON and nested elements. No network or script execution.
private final class HTMLNode {
    let tag: String
    var attributes: [String: String] = [:]
    weak var parent: HTMLNode?
    var children: [HTMLNode] = []
    var rawText = ""
    init(_ tag: String) { self.tag = tag }
    var text: String { decode(rawText) + children.map(\.text).joined() }
    var descendants: [HTMLNode] { children.flatMap { [$0] + $0.descendants } }

    static func parse(_ html: String) -> HTMLNode {
        let root = HTMLNode("root"); var stack = [root]
        let pattern = #"<!--[\s\S]*?-->|<script\b(?:[^>\"']|\"[^\"]*\"|'[^']*')*>[\s\S]*?</script\s*>|<(?:[^>\"']|\"[^\"]*\"|'[^']*')*>|[^<]+"#
        for token in CinemarFixtureParser.matches(pattern, html).map({ $0[0] }) {
            if token.hasPrefix("<!--") || token.hasPrefix("<!") { continue }
            if token.hasPrefix("</") {
                let tag = token.dropFirst(2).prefix { $0.isLetter || $0.isNumber }.lowercased()
                if let index = stack.lastIndex(where: { $0.tag == tag }), index > 0 { stack.removeSubrange(index...) }
            } else if token.hasPrefix("<") {
                let tag = token.dropFirst().prefix { $0.isLetter || $0.isNumber }.lowercased()
                guard !tag.isEmpty else { continue }
                let node = HTMLNode(tag)
                let opening = token.prefix { $0 != ">" }
                for attr in CinemarFixtureParser.matches(#"([\w:-]+)\s*=\s*(?:\"([^\"]*)\"|'([^']*)'|([^\s>]+))"#, String(opening)) {
                    node.attributes[attr[1].lowercased()] = decode(attr[2].isEmpty ? (attr[3].isEmpty ? attr[4] : attr[3]) : attr[2])
                }
                node.parent = stack.last; stack.last?.children.append(node)
                if tag == "script" {
                    if let begin = token.firstIndex(of: ">"), let end = token.range(of: "</script", options: [.caseInsensitive, .backwards]) {
                        node.rawText = String(token[token.index(after: begin)..<end.lowerBound])
                    }
                } else if !["img", "meta", "link", "input", "br", "hr", "source", "area", "base", "wbr"].contains(tag), !token.hasSuffix("/>") { stack.append(node) }
            } else { stack.last?.rawText += token }
        }
        return root
    }
}

private func decode(_ text: String) -> String {
    var result = text
    for (entity, value) in ["&quot;": "\"", "&#39;": "'", "&lt;": "<", "&gt;": ">", "&nbsp;": " "] { result = result.replacingOccurrences(of: entity, with: value) }
    for match in CinemarFixtureParser.matches(#"&#(x[0-9a-f]+|[0-9]+);"#, result) {
        let raw = match[1]
        let number = raw.lowercased().hasPrefix("x") ? UInt32(raw.dropFirst(), radix: 16) : UInt32(raw)
        if let number, let scalar = UnicodeScalar(number) { result = result.replacingOccurrences(of: match[0], with: String(scalar)) }
    }
    return result.replacingOccurrences(of: "&amp;", with: "&")
}
