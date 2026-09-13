import Foundation

enum APIConfig {
    static let baseURL = URL(string: "https://api.atodo.fun/")!
    static let timeout: TimeInterval = 30
    static let headers = [
        "Accept": "application/json, text/plain, */*",
        "Accept-Language": "ru-RU,ru;q=0.9,en;q=0.8",
        "Accept-Encoding": "identity",
        "Connection": "close",
        "Origin": "https://atodo.fun",
        "Referer": "https://atodo.fun/fun.html",
        "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15 Version/16.0 Mobile/15E148 Safari/604.1"
    ]
}
