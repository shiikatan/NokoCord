import Foundation

struct DiscordREST: Sendable {
    let http: HTTPClient
    func account(token: String) async throws -> DiscordUser {
        try JSONDecoder().decode(DiscordUser.self, from: await get(path: "users/@me", token: token))
    }
    func guilds(token: String) async throws -> [DiscordGuild] {
        var result: [DiscordGuild] = [], after: String?
        // Bound pagination even if the remote service repeats a full page.
        for _ in 0..<10 {
            var query = [URLQueryItem(name: "limit", value: "200"),
                         URLQueryItem(name: "with_counts", value: "true")]
            if let after { query.append(.init(name: "after", value: after)) }
            let page = try JSONDecoder().decode([DiscordGuild].self, from: await get(path: "users/@me/guilds", token: token, query: query))
            guard page.count <= 200 else { throw TransportError.responseTooLarge }
            var seen = Set(result.map(\.id))
            result.append(contentsOf: page.filter { seen.insert($0.id).inserted })
            guard page.count == 200, let last = page.last?.id, last != after else { break }
            after = last
        }
        return result
    }
    private func get(path: String, token: String, query: [URLQueryItem] = []) async throws -> Data {
        var components = URLComponents(string: "https://discord.com/api/v10/\(path)")!
        components.queryItems = query.isEmpty ? nil : query
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("NokoCord/1.0", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return try await http.request(request)
    }
}
