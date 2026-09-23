import Foundation

/// Minimal GraphQL transport for the Hardcover API (HTTP, not an SDK — project rule).
///
/// An actor so the rate-limit bookkeeping is serialized: Hardcover counts every TOP-LEVEL
/// field as one request, the free tier is ~60/min with a burst of ~10, and it publishes its
/// own `RateLimit` headers. We read those and self-throttle rather than waiting to be 429'd.
///
/// Mutation shapes below are taken from Hardcover's own docs repo (schemas, scopes, status
/// ids) plus the query documents used by the `audiobookshelf-hardcover-sync` project, which
/// talks to this same API in production. The mutations are custom Hasura *actions*, not
/// generated CRUD, which has two consequences worth remembering:
///   • the argument names are hand-written (`user_book_read:`, `object:`), not `_set`/`where`;
///   • the payload carries an `error` STRING field, so HTTP 200 does not mean it worked.
actor HardcoverClient {
    private let session: URLSession
    private let tokenProvider: @Sendable () -> String?

    /// When set, we're inside a rate-limit cooldown and must not send until it passes.
    private var throttledUntil: Date?

    init(session: URLSession = .shared,
         tokenProvider: @escaping @Sendable () -> String? = { HardcoverSettings.token }) {
        self.session = session
        self.tokenProvider = tokenProvider
    }

    // MARK: Transport

    /// Run `query` and decode the `data` object as `T`.
    func run<T: Decodable>(_ query: String,
                           variables: [String: Any] = [:],
                           as type: T.Type = T.self) async throws -> T {
        guard let token = tokenProvider(), !token.isEmpty else { throw HardcoverError.notConfigured }

        if let until = throttledUntil, until > Date() {
            try await Task.sleep(for: .seconds(until.timeIntervalSinceNow))
        }

        var request = URLRequest(url: HardcoverSettings.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "authorization")
        request.timeoutInterval = 20
        var body: [String: Any] = ["query": query]
        if !variables.isEmpty { body["variables"] = variables }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw HardcoverError.decoding("no HTTP response")
        }
        noteRateLimit(http)

        switch http.statusCode {
        case 200: break
        case 401: throw HardcoverError.unauthorized
        case 429:
            let retry = (http.value(forHTTPHeaderField: "Retry-After")).flatMap(TimeInterval.init)
            throttledUntil = Date().addingTimeInterval(retry ?? 60)
            throw HardcoverError.rateLimited(retryAfter: retry)
        default: throw HardcoverError.server(status: http.statusCode)
        }

        // GraphQL transport-level errors come back inside a 200.
        if let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let errors = envelope["errors"] as? [[String: Any]] {
            throw HardcoverError.graphQL(errors.compactMap { $0["message"] as? String })
        }

        do {
            return try JSONDecoder().decode(GraphQLResponse<T>.self, from: data).data
        } catch {
            throw HardcoverError.decoding(String(describing: error))
        }
    }

    /// Hardcover publishes IETF-draft `RateLimit` headers. Back off *before* being throttled:
    /// an outbox flush after a day offline can easily exceed a burst of 10.
    private func noteRateLimit(_ http: HTTPURLResponse) {
        guard let header = http.value(forHTTPHeaderField: "RateLimit") else { return }
        // Shape: `"Free";r=8;t=42, "daily";r=4231;t=51234` — r = remaining, t = seconds to reset.
        let minuteBucket = header.split(separator: ",").first.map(String.init) ?? header
        let fields = minuteBucket.split(separator: ";").reduce(into: [String: Double]()) { acc, part in
            let kv = part.split(separator: "=", maxSplits: 1)
            if kv.count == 2, let value = Double(kv[1]) {
                acc[kv[0].trimmingCharacters(in: .whitespaces)] = value
            }
        }
        guard let remaining = fields["r"] else { return }
        if remaining <= 1, let reset = fields["t"] {
            throttledUntil = Date().addingTimeInterval(reset)
        } else {
            throttledUntil = nil
        }
    }
}

// MARK: - Envelope

private struct GraphQLResponse<T: Decodable>: Decodable {
    let data: T
}

/// Payload shared by Hardcover's custom mutations: an id plus an optional logical error.
struct HardcoverActionPayload: Decodable {
    let id: Int?
    let error: String?

    /// Throw if the action reported a logical failure, otherwise return the id.
    func requireId() throws -> Int {
        if let error, !error.isEmpty { throw HardcoverError.action(error) }
        guard let id else { throw HardcoverError.action("Hardcover returned no id.") }
        return id
    }

    func throwIfFailed() throws {
        if let error, !error.isEmpty { throw HardcoverError.action(error) }
    }
}
