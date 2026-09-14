import Foundation
import os

enum APIError: LocalizedError {
    case invalidResponse, http(Int), emptyResponse, invalidJSON, noConnection, cancelled
    var errorDescription: String? {
        switch self { case .invalidResponse, .invalidJSON: "Сервер вернул некорректные данные"; case .http(let code): code >= 500 ? "Сервер недоступен" : "Ошибка запроса (\(code))"; case .emptyResponse: "Сервер вернул пустой ответ"; case .noConnection: "Нет подключения к интернету"; case .cancelled: "Запрос отменён" }
    }
}

protocol ProviderAPI: Sendable {
    func get(path: String, query: [String: String]) async throws -> JSONValue
}
extension ProviderAPI {
    func get(path: String) async throws -> JSONValue { try await get(path: path, query: [:]) }
}

actor APIClient: ProviderAPI {
    static let shared = APIClient()
    private let session: URLSession
    private let logger = Logger(subsystem: "com.jirox.jiroxtv", category: "API")

    init() {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = APIConfig.timeout
        configuration.timeoutIntervalForResource = 40
        configuration.httpCookieStorage = .shared
        configuration.httpShouldSetCookies = true
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration)
    }

    func get(path: String, query: [String: String] = [:]) async throws -> JSONValue {
        var components = URLComponents(url: APIConfig.baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        components.queryItems = query.isEmpty ? nil : query.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = components.url else { throw APIError.invalidResponse }
        var request = URLRequest(url: url, timeoutInterval: APIConfig.timeout)
        APIConfig.headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        logger.debug("GET \(path, privacy: .public)")
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
            guard (200..<300).contains(http.statusCode) else { throw APIError.http(http.statusCode) }
            guard !data.isEmpty else { throw APIError.emptyResponse }
            do { return try JSONDecoder().decode(JSONValue.self, from: data) }
            catch { logger.error("JSON decode failed"); throw APIError.invalidJSON }
        } catch is CancellationError { throw APIError.cancelled }
        catch let error as APIError { throw error }
        catch let error as URLError where [.notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost].contains(error.code) { throw APIError.noConnection }
        catch { logger.error("Network request failed"); throw error }
    }
}
