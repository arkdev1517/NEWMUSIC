import Foundation

struct ListenTogetherFailure: LocalizedError, Sendable {
    var code: String
    var message: String
    var statusCode: Int?

    var errorDescription: String? {
        message.isEmpty ? "Listen Together request failed (\(code))." : message
    }
}

actor ListenTogetherClient {
    private let session: URLSession
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(session: URLSession = .shared) {
        self.session = session
        encoder.outputFormatting = [.sortedKeys]
    }

    func serverTime(baseURL: URL) async throws -> Int64 {
        let data = try await request(path: "api/time", baseURL: baseURL)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let value = object?["serverMs"] as? NSNumber else {
            throw ListenTogetherFailure(code: "invalid_response", message: "The party server returned no clock value.", statusCode: nil)
        }
        return value.int64Value
    }

    func preview(code: String, baseURL: URL) async throws -> PartyPreview {
        let data = try await request(path: "api/parties/\(code)/preview", baseURL: baseURL)
        return try decoder.decode(PartyPreview.self, from: data)
    }

    func createParty(_ body: PartyJoinRequest, baseURL: URL) async throws -> PartyMembership {
        let data = try await request(
            path: "api/parties",
            method: "POST",
            baseURL: baseURL,
            body: try encoder.encode(body)
        )
        return try decoder.decode(PartyMembership.self, from: data)
    }

    func joinParty(code: String, body: PartyJoinRequest, baseURL: URL) async throws -> PartyMembership {
        let data = try await request(
            path: "api/parties/\(code)/join",
            method: "POST",
            baseURL: baseURL,
            body: try encoder.encode(body)
        )
        return try decoder.decode(PartyMembership.self, from: data)
    }

    func snapshot(code: String, token: String, baseURL: URL) async throws -> PartySnapshot {
        let data = try await request(
            path: "api/parties/\(code)",
            baseURL: baseURL,
            token: token
        )
        return try decoder.decode(PartySnapshot.self, from: data)
    }

    func leave(code: String, token: String, baseURL: URL) async throws {
        _ = try await request(
            path: "api/parties/\(code)/leave",
            method: "POST",
            baseURL: baseURL,
            token: token,
            body: Data("{}".utf8)
        )
    }

    func webSocket(code: String, token: String, baseURL: URL) throws -> URLSessionWebSocketTask {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw ListenTogetherFailure(code: "invalid_server", message: "The party server address is invalid.", statusCode: nil)
        }
        components.scheme = "wss"
        components.path = "/ws/parties/\(code)"
        components.query = nil
        components.fragment = nil
        guard let url = components.url else {
            throw ListenTogetherFailure(code: "invalid_server", message: "The party WebSocket address is invalid.", statusCode: nil)
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return session.webSocketTask(with: request)
    }

    private func request(
        path: String,
        method: String = "GET",
        baseURL: URL,
        token: String? = nil,
        body: Data? = nil
    ) async throws -> Data {
        guard let url = URL(string: "\(baseURL.absoluteString)/\(path)") else {
            throw ListenTogetherFailure(code: "invalid_url", message: "The party server address is invalid.", statusCode: nil)
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ListenTogetherFailure(code: "invalid_response", message: "The party server returned an invalid response.", statusCode: nil)
        }
        guard (200..<300).contains(http.statusCode) else {
            if let error = try? decoder.decode(PartyWireError.self, from: data) {
                throw ListenTogetherFailure(code: error.code, message: error.message, statusCode: http.statusCode)
            }
            throw ListenTogetherFailure(
                code: "http_\(http.statusCode)",
                message: "The party server returned HTTP \(http.statusCode).",
                statusCode: http.statusCode
            )
        }
        return data
    }
}
