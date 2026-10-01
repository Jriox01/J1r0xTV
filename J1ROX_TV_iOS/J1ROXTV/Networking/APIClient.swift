import Foundation
import os

enum APIError: LocalizedError {
    case invalidResponse, http(Int), emptyResponse, invalidJSON, noConnection, cancelled, secureConnection
    var errorDescription: String? {
        switch self { case .invalidResponse, .invalidJSON: "Сервер вернул некорректные данные"; case .http(let code): code >= 500 ? "Сервер недоступен" : "Ошибка запроса (\(code))"; case .emptyResponse: "Сервер вернул пустой ответ"; case .noConnection: "Нет подключения к интернету"; case .cancelled: "Запрос отменён"; case .secureConnection: "Не удалось установить защищённое соединение с Atodo. Возможно, сертификат сервера истёк. Попробуйте позже." }
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
        catch let error as URLError where [.secureConnectionFailed, .serverCertificateHasBadDate, .serverCertificateUntrusted, .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid].contains(error.code) { throw APIError.secureConnection }
        catch let error as URLError where error.code == .cancelled { throw APIError.cancelled }
        catch let error as URLError where [.notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost].contains(error.code) { throw APIError.noConnection }
        catch { logger.error("Network request failed"); throw error }
    }
}


/// Official TMDB metadata API. Video providers keep their own API client.
actor TMDBClient: ProviderAPI {
    static let shared = TMDBClient()
    private let session = URLSession.shared

    func get(path: String, query: [String: String] = [:]) async throws -> JSONValue {
        let token = (Bundle.main.object(forInfoDictionaryKey: "TMDBReadAccessToken") as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let key = (Bundle.main.object(forInfoDictionaryKey: "TMDBAPIKey") as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let validToken = !token.isEmpty && !token.hasPrefix("$(")
        let validKey = !key.isEmpty && !key.hasPrefix("$(")
        guard validToken || validKey else { throw TMDBError.missingToken }
        let endpoint: String
        var parameters = query
        switch path {
        case "api/list":
            guard let type = parameters.removeValue(forKey: "type_movie"), ["movie", "tv"].contains(type) else {
                throw APIError.invalidResponse
            }
            endpoint = "\(type)/popular"
        case "api/search": endpoint = "search/multi"; parameters["include_adult"] = "false"
        default:
            guard path.hasPrefix("api/details/") else { throw APIError.invalidResponse }
            let detail = String(path.dropFirst("api/details/".count))
            let parts = detail.split(separator: "/")
            guard parts.count == 2, ["movie", "tv"].contains(String(parts[0])), Int(parts[1]) != nil else {
                throw APIError.invalidResponse
            }
            endpoint = detail
            parameters["append_to_response"] = "external_ids"
        }
        parameters["language"] = "ru-RU"
        if !validToken { parameters["api_key"] = key }
        var components = URLComponents(url: URL(string: "https://api.themoviedb.org/3/")!
            .appendingPathComponent(endpoint), resolvingAgainstBaseURL: false)!
        components.queryItems = parameters.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = components.url else { throw APIError.invalidResponse }
        var request = URLRequest(url: url, timeoutInterval: APIConfig.timeout)
        if validToken { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        if http.statusCode == 401 || http.statusCode == 403 { throw TMDBError.invalidToken }
        guard (200..<300).contains(http.statusCode) else { throw APIError.http(http.statusCode) }
        guard !data.isEmpty else { throw APIError.emptyResponse }
        do { return try JSONDecoder().decode(JSONValue.self, from: data) }
        catch { throw APIError.invalidJSON }
    }
}

enum TMDBError: LocalizedError {
    case missingToken, invalidToken
    var errorDescription: String? {
        switch self {
        case .missingToken: "Для каталога TMDB нужно настроить API Read Access Token при сборке приложения."
        case .invalidToken: "TMDB отклонил токен доступа. Проверьте настройки сборки."
        }
    }
}
