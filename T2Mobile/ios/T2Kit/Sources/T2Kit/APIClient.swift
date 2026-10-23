import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The app's only contact with the server: read-only queries to t2api (docs/API.md).
public struct APIClient: Sendable {
    public enum APIError: Error, CustomStringConvertible, LocalizedError {
        case badURL
        case http(Int, String)
        /// the request never got an answer: the URLError's code (when there was one) and its text
        case transport(URLError.Code?, String)
        /// the database version the device holds is no longer served: everything
        /// fetched for that dataset (sample order included) belongs to the old database
        case versionChanged
        public var description: String {
            switch self {
            case .versionChanged: return "the database on the server was updated"
            case .badURL: return "bad URL"
            case .http(let code, let msg): return msg.isEmpty ? "server answered \(code)" : "server answered \(code): \(msg)"
            case .transport(_, let msg): return msg
            }
        }
        public var errorDescription: String? { description }
        /// the device could not reach the network at all (as opposed to the server failing)
        public var isOffline: Bool {
            if case .transport(let code?, _) = self { return Self.offlineCodes.contains(code) }
            return false
        }
        public static let offlineCodes: [URLError.Code] = [.notConnectedToInternet, .networkConnectionLost, .cannotFindHost,
                                                           .cannotConnectToHost, .timedOut, .dataNotAllowed, .internationalRoamingOff]
    }

    /// `T2 iOS <marketing version> (<build>)`: the service classifies clients by the prefix "T2 iOS"
    public static var userAgent: String {
        let info = Bundle.main.infoDictionary
        let version = (info?["CFBundleShortVersionString"] as? String) ?? "0"
        let build = (info?["CFBundleVersion"] as? String) ?? "0"
        return "T2 iOS \(version) (\(build))"
    }
    /// a session with a response cache big enough for the 2.6 MB clinical table (the shared
    /// session's cache never stores an answer above about 0.5 MB)
    public static let cachingSession: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.urlCache = URLCache(memoryCapacity: 20 * 1024 * 1024, diskCapacity: 200 * 1024 * 1024, diskPath: "t2api")
        cfg.requestCachePolicy = .useProtocolCachePolicy
        return URLSession(configuration: cfg)
    }()
    /// the service limits one request to this many names
    public static let maxProbesPerRequest = 100

    public let baseURL: URL
    private let session: URLSession

    public init(baseURL: URL, session: URLSession = APIClient.cachingSession) {
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
    /// `fill`: "na" (the default: what every client got before), "zero" or "floor" for the
    /// not-detected cells of the types that offer it; a fill the answer did not list is a 400.
    /// The answers' `fill_options` come back in `info`. (The device's URL cache keys on the whole
    /// address, so every fill is kept apart; "na" adds nothing to it: today's address.)
    public func values(_ dataset: String, probes names: [String], version: String? = nil, fill: String = "na") async throws -> (columns: [Column], missing: [String], info: ValuesInfo) {
        let chunks = stride(from: 0, to: names.count, by: Self.maxProbesPerRequest).map {
            Array(names[$0..<min($0 + Self.maxProbesPerRequest, names.count)])
        }
        // A chunk whose types offer no such fill is refused with a 400; only that chunk is
        // asked again without `fill` (as the R client does). `refused` records the first refusal.
        func fetchChunk(_ chunk: [String], fill: String) async throws -> Values {
            var query = ["probes": chunk.joined(separator: ",")]
            if let version { query["v"] = version }
            if fill != "na" { query["fill"] = fill }
            let r = try await get("v1/\(dataset)/values", query: query, as: Values.self)
            if let version, let served = r.version, served != version { throw APIError.versionChanged }
            return r
        }
        func fetchOrRetry(_ chunk: [String]) async throws -> (Values, APIError?) {
            do { return (try await fetchChunk(chunk, fill: fill), nil) } catch let e as APIError {
                if fill != "na", case .http(400, let msg) = e, msg.contains("fill not available") {
                    return (try await fetchChunk(chunk, fill: "na"), e)
                }
                throw e
            }
        }
        // one request: no task overhead. Several: all at once, put back in the order asked.
        var answers: [Values?] = Array(repeating: nil, count: chunks.count)
        var refusals: [APIError] = []
        if chunks.count == 1 {
            let (r, refusal) = try await fetchOrRetry(chunks[0])
            answers[0] = r; if let refusal { refusals.append(refusal) }
        } else if chunks.count > 1 {
            try await withThrowingTaskGroup(of: (Int, Values, APIError?).self) { group in
                for (i, chunk) in chunks.enumerated() { group.addTask { let (r, e) = try await fetchOrRetry(chunk); return (i, r, e) } }
                for try await (i, r, e) in group { answers[i] = r; if let e { refusals.append(e) } }
            }
        }
        // every chunk refused: the fill is not available for this set; the caller decides
        if !chunks.isEmpty, refusals.count == chunks.count { throw refusals[0] }
        var columns: [Column] = [], missing: [String] = []
        for r in answers.compactMap({ $0 }) { columns += r.columns; missing += r.missing }
        return (columns, missing, ValuesInfo.merge(answers.compactMap { $0 }))
    }

    /// A message to the owner through the server (the recipient's address stays on the
    /// server). `started`: seconds since the form appeared (a bot deterrent on the server).
    public struct ContactMessage: Encodable, Sendable {
        public var name: String
        public var affiliation: String
        public var email: String
        public var message: String
        public var started: Double
        public var app: String
        public init(name: String, affiliation: String, email: String, message: String, started: Double, app: String) {
            self.name = name; self.affiliation = affiliation; self.email = email; self.message = message; self.started = started; self.app = app
        }
    }
    public func sendContact(_ m: ContactMessage) async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/contact"))
        request.httpMethod = "POST"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(m)
        let (data, response) = try await fetch(request)
        guard let http = response as? HTTPURLResponse else { throw APIError.transport(nil, "no HTTP response") }
        guard http.statusCode == 200 else {
            let body = (try? JSONDecoder().decode([String: String].self, from: data))?["error"] ?? ""
            throw APIError.http(http.statusCode, body)
        }
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
        guard let http = response as? HTTPURLResponse else { throw APIError.transport(nil, "no HTTP response") }
        if http.statusCode == 409 { throw APIError.versionChanged }
        guard http.statusCode == 200 else {
            throw APIError.http(http.statusCode, String(data: data.prefix(300), encoding: .utf8) ?? "")
        }
        return try Self.decoder.decode(T.self, from: data)
    }

    /// holds the running data task so that a cancelled Swift task cancels the request
    private final class TaskBox: @unchecked Sendable {
        private let lock = NSLock()
        private var task: URLSessionDataTask?
        private var cancelled = false
        func set(_ t: URLSessionDataTask) {
            lock.lock(); task = t; let c = cancelled; lock.unlock()
            if c { t.cancel() }
        }
        func cancel() {
            lock.lock(); cancelled = true; let t = task; lock.unlock()
            t?.cancel()
        }
    }

    // callback form: available on every platform Foundation runs on, Linux included
    private func fetch(_ request: URLRequest) async throws -> (Data, URLResponse) {
        var request = request
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        let box = TaskBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<(Data, URLResponse), Error>) in
                let task = session.dataTask(with: request) { data, response, error in
                    if let error {
                        if let u = error as? URLError {
                            if u.code == .cancelled { cont.resume(throwing: CancellationError()); return }
                            cont.resume(throwing: APIError.transport(u.code, u.localizedDescription)); return
                        }
                        cont.resume(throwing: APIError.transport(nil, error.localizedDescription)); return
                    }
                    guard let data, let response else { cont.resume(throwing: APIError.transport(nil, "empty response")); return }
                    cont.resume(returning: (data, response))
                }
                box.set(task)
                task.resume()
            }
        } onCancel: { box.cancel() }
    }
}
