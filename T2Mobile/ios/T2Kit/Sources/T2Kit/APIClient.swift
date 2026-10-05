import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The app's only contact with the server: read-only queries to t2api (docs/API.md).
public struct APIClient: Sendable {
    public enum APIError: Error, CustomStringConvertible {
        case badURL
        case http(Int, String)
        case transport(String)
        /// the server no longer serves the database version the device holds: everything
        /// fetched for that dataset (sample order included) belongs to the old database
        case versionChanged
        public var description: String {
            switch self {
            case .versionChanged: return "the database on the server was updated"
            case .badURL: return "bad URL"
            case .http(let code, let msg): return "server answered \(code): \(msg)"
            case .transport(let msg): return msg
            }
        }
    }
    /// the service limits one request to this many names
    public static let maxProbesPerRequest = 100

    public let baseURL: URL
    private let session: URLSession

    public init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    public func datasets() async throws -> [DatasetSummary] {
        try await get("v1/datasets", as: DatasetList.self).datasets
    }
    public func meta(_ dataset: String) async throws -> DatasetMeta {
        try await get("v1/\(dataset)/meta", as: DatasetMeta.self)
    }
    /// sample ids and every clinical column: fetch once per dataset version and keep
    /// `version` (from `meta`): the server answers only if it still serves that database, and
    /// the response can then be kept by the system's URL cache for good
    public func clinical(_ dataset: String, version: String? = nil) async throws -> Clinical {
        try await get("v1/\(dataset)/clinical", query: version.map { ["v": $0] } ?? [:], as: Clinical.self)
    }
    public func searchProbes(_ dataset: String, query: String, limit: Int = 50) async throws -> ProbeSearch {
        try await get("v1/\(dataset)/probes", query: ["q": query, "limit": String(limit)], as: ProbeSearch.self)
    }
    /// the columns for `names` (any number: sent in requests of at most 100), and the names
    /// the dataset does not have. Pass the `version` the device's sample list belongs to:
    /// values of another database version must never be attached to it (`versionChanged`).
    public func values(_ dataset: String, probes names: [String], version: String? = nil) async throws -> (columns: [Column], missing: [String]) {
        var columns: [Column] = [], missing: [String] = []
        var start = 0
        while start < names.count {
            let chunk = Array(names[start..<min(start + Self.maxProbesPerRequest, names.count)])
            var query = ["probes": chunk.joined(separator: ",")]
            if let version { query["v"] = version }
            let r = try await get("v1/\(dataset)/values", query: query, as: Values.self)
            if let version, let served = r.version, served != version { throw APIError.versionChanged }
            columns += r.columns
            missing += r.missing
            start += Self.maxProbesPerRequest
        }
        return (columns, missing)
    }

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    func get<T: Decodable>(_ path: String, query: [String: String] = [:], as type: T.Type) async throws -> T {
        guard var parts = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false) else {
            throw APIError.badURL
        }
        if !query.isEmpty {
            parts.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
            // "+" must not be read as a space by the server ("NKX2-1+..." style names)
            parts.percentEncodedQuery = parts.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        }
        guard let url = parts.url else { throw APIError.badURL }
        var request = URLRequest(url: url)
        // A request that names a database version (?v=) may be answered from the device's
        // cache for good. One that does not is how the current version is learned
        // (/datasets, /meta) or a search: it always goes to the server.
        if query["v"] == nil { request.cachePolicy = .reloadIgnoringLocalCacheData }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        var (data, response) = try await fetch(request)
        // 503: the service is restarting on a new database file; it is back within seconds
        var tries = 0
        while (response as? HTTPURLResponse)?.statusCode == 503 && tries < 3 {
            tries += 1
            try await Task.sleep(nanoseconds: 2_000_000_000)
            (data, response) = try await fetch(request)
        }
        guard let http = response as? HTTPURLResponse else { throw APIError.transport("no HTTP response") }
        if http.statusCode == 409 { throw APIError.versionChanged }
        guard http.statusCode == 200 else {
            throw APIError.http(http.statusCode, String(data: data.prefix(300), encoding: .utf8) ?? "")
        }
        return try Self.decoder.decode(T.self, from: data)
    }

    // callback form: available on every platform Foundation runs on, Linux included
    private func fetch(_ request: URLRequest) async throws -> (Data, URLResponse) {
        try await withCheckedThrowingContinuation { cont in
            session.dataTask(with: request) { data, response, error in
                if let error { cont.resume(throwing: APIError.transport(error.localizedDescription)); return }
                guard let data, let response else { cont.resume(throwing: APIError.transport("empty response")); return }
                cont.resume(returning: (data, response))
            }.resume()
        }
    }
}
