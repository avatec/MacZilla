import Foundation

public struct WebDAVConfig: Sendable {
    public var baseURL: URL
    public var username: String
    public var password: String

    public init(baseURL: URL, username: String = "", password: String = "") {
        self.baseURL = baseURL
        self.username = username
        self.password = password
    }

    /// `host` może być pełnym adresem (https://host/dav) albo samą nazwą hosta.
    public init(site: SiteProfile, password: String) throws {
        var comps: URLComponents
        if site.host.contains("://") {
            guard let c = URLComponents(string: site.host), c.host != nil else {
                throw FileProviderError.io("Nieprawidłowy adres WebDAV")
            }
            comps = c
        } else {
            comps = URLComponents()
            comps.scheme = site.port == 80 ? "http" : "https"
            comps.host = site.host
            if !site.startPath.isEmpty { comps.path = site.startPath.hasPrefix("/") ? site.startPath : "/" + site.startPath }
        }
        if comps.port == nil, ![80, 443, 0].contains(site.port), !site.host.contains("://") { comps.port = site.port }
        guard let scheme = comps.scheme, ["http", "https"].contains(scheme), let url = comps.url else {
            throw FileProviderError.io("Obsługiwane są tylko adresy http/https")
        }
        self.init(baseURL: url, username: site.username, password: password)
    }
}

public final class WebDAVProvider: FileProvider, @unchecked Sendable {
    public let id: String
    public let displayName: String
    public let capabilities: ProviderCapabilities = [.resume]
    public var homePath: String { "/" }

    private let config: WebDAVConfig
    private let session: URLSession
    private let basePath: String
    private let authHeader: String?

    public init(config: WebDAVConfig) {
        self.config = config
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 60
        c.httpShouldSetCookies = false
        c.urlCache = nil
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: c)
        var bp = config.baseURL.path(percentEncoded: true)
        while bp.hasSuffix("/") { bp.removeLast() }
        basePath = bp
        let host = config.baseURL.host() ?? "webdav"
        id = "webdav:\(config.username)@\(config.baseURL.absoluteString)"
        displayName = "\(host) (WebDAV)"
        authHeader = config.username.isEmpty ? nil
            : "Basic " + Data("\(config.username):\(config.password)".utf8).base64EncodedString()
    }

    deinit { session.finishTasksAndInvalidate() }

    // MARK: - HTTP

    private func url(_ path: String) throws -> URL {
        var comps = URLComponents(url: config.baseURL, resolvingAgainstBaseURL: false)!
        let enc = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        comps.percentEncodedPath = basePath + (enc.hasPrefix("/") ? enc : "/" + enc)
        comps.query = nil
        comps.fragment = nil
        guard let u = comps.url else { throw FileProviderError.io("Nieprawidłowa ścieżka: \(path)") }
        return u
    }

    private func request(_ method: String, _ path: String, headers: [String: String] = [:]) throws -> URLRequest {
        var r = URLRequest(url: try url(path))
        r.httpMethod = method
        if let authHeader { r.setValue(authHeader, forHTTPHeaderField: "Authorization") }
        for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
        return r
    }

    private func check(_ code: Int, _ path: String, method: String) throws {
        switch code {
        case 200..<300: return
        case 401: throw FileProviderError.io("Logowanie nieudane (HTTP 401)")
        case 403: throw FileProviderError.io("Brak uprawnień: \(path)")
        case 404, 410: throw FileProviderError.notFound(path)
        case 405 where method == "MKCOL": throw FileProviderError.alreadyExists(path)
        case 412: throw FileProviderError.alreadyExists(path)
        default: throw FileProviderError.io("Serwer zwrócił HTTP \(code)")
        }
    }

    private func send(_ method: String, _ path: String, headers: [String: String] = [:], body: Data? = nil) async throws -> Data {
        var r = try request(method, path, headers: headers)
        r.httpBody = body
        let (data, resp) = try await run { try await self.session.data(for: r) }
        try check((resp as? HTTPURLResponse)?.statusCode ?? 0, path, method: method)
        return data
    }

    private func run<T>(_ op: () async throws -> T) async throws -> T {
        do { return try await op() }
        catch let e as URLError where e.code == .cancelled { throw CancellationError() }
        catch let e as URLError { throw FileProviderError.io(e.localizedDescription) }
    }

    // MARK: - FileProvider

    public func connect() async throws {
        _ = try await propfind("/", depth: 0)
    }

    public func disconnect() async {}

    private func propfind(_ path: String, depth: Int) async throws -> [DAVEntry] {
        let body = Data("""
        <?xml version="1.0" encoding="utf-8"?><d:propfind xmlns:d="DAV:"><d:prop>\
        <d:resourcetype/><d:getcontentlength/><d:getlastmodified/></d:prop></d:propfind>
        """.utf8)
        let data = try await send("PROPFIND", path, headers: ["Depth": String(depth), "Content-Type": "application/xml"], body: body)
        return try DAVParser.parse(data)
    }

    private func relative(_ href: String) -> String {
        var p = URL(string: href)?.path(percentEncoded: true) ?? href
        if p.isEmpty { p = href }
        p = p.removingPercentEncoding ?? p
        let bp = basePath.removingPercentEncoding ?? basePath
        if !bp.isEmpty, p.hasPrefix(bp) { p.removeFirst(bp.count) }
        while p.count > 1, p.hasSuffix("/") { p.removeLast() }
        return p.isEmpty ? "/" : (p.hasPrefix("/") ? p : "/" + p)
    }

    private func item(_ e: DAVEntry) -> FileItem {
        let path = relative(e.href)
        let name = PathUtil.lastComponent(path)
        return FileItem(name: name, path: path, kind: e.isDirectory ? .directory : .file,
                        size: e.isDirectory ? nil : e.size, modified: e.modified, isHidden: name.hasPrefix("."))
    }

    public func list(_ path: String) async throws -> [FileItem] {
        let self_ = relative(try url(path).path(percentEncoded: true))
        return try await propfind(path, depth: 1)
            .map(item)
            .filter { $0.path != self_ }
    }

    public func stat(_ path: String) async throws -> FileItem {
        guard let e = try await propfind(path, depth: 0).first else { throw FileProviderError.notFound(path) }
        var it = item(e)
        if path == "/" { it = FileItem(name: "/", path: "/", kind: .directory) }
        return it
    }

    public func read(_ path: String, offset: Int64) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let r = try request("GET", path, headers: offset > 0 ? ["Range": "bytes=\(offset)-"] : [:])
                    let (bytes, resp) = try await run { try await self.session.bytes(for: r) }
                    let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                    try check(code, path, method: "GET")
                    if offset > 0 && code != 206 { throw FileProviderError.unsupported("Serwer nie obsługuje wznawiania") }
                    var buf = Data()
                    for try await b in bytes {
                        buf.append(b)
                        if buf.count >= 64 * 1024 { continuation.yield(buf); buf = Data() }
                    }
                    if !buf.isEmpty { continuation.yield(buf) }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func write(_ path: String, from data: AsyncThrowingStream<Data, Error>, options: WriteOptions) async throws {
        guard options.offset == 0 else { throw FileProviderError.unsupported("Wznawianie wysyłania w WebDAV") }
        if !options.overwrite, (try? await stat(path)) != nil { throw FileProviderError.alreadyExists(path) }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("mz-dav-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: tmp.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let h = try FileHandle(forWritingTo: tmp)
        do {
            for try await chunk in data { try h.write(contentsOf: chunk) }
            try h.close()
        } catch {
            try? h.close()
            throw error
        }
        let r = try request("PUT", path)
        let (_, resp) = try await run { try await self.session.upload(for: r, fromFile: tmp) }
        try check((resp as? HTTPURLResponse)?.statusCode ?? 0, path, method: "PUT")
    }

    public func makeDirectory(_ path: String) async throws {
        _ = try await send("MKCOL", path)
    }

    public func rename(_ from: String, to: String) async throws {
        _ = try await send("MOVE", from, headers: ["Destination": try url(to).absoluteString, "Overwrite": "F"])
    }

    public func delete(_ path: String) async throws {
        _ = try await send("DELETE", path)
    }
}

struct DAVEntry {
    var href = ""
    var isDirectory = false
    var size: Int64?
    var modified: Date?
}

/// Parser odpowiedzi multistatus (207) – ignoruje przestrzenie nazw, rozpoznaje elementy po nazwie lokalnej.
final class DAVParser: NSObject, XMLParserDelegate {
    private var entries: [DAVEntry] = []
    private var current: DAVEntry?
    private var text = ""

    static func parse(_ data: Data) throws -> [DAVEntry] {
        let p = XMLParser(data: data)
        let d = DAVParser()
        p.delegate = d
        p.shouldResolveExternalEntities = false
        guard p.parse() else { throw FileProviderError.io("Nieprawidłowa odpowiedź WebDAV") }
        return d.entries
    }

    private func local(_ name: String) -> String {
        (name.split(separator: ":").last.map(String.init) ?? name).lowercased()
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String] = [:]) {
        text = ""
        switch local(name) {
        case "response": current = DAVEntry()
        case "collection": current?.isDirectory = true
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters s: String) { text += s }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch local(name) {
        case "href": if current != nil, current?.href.isEmpty == true { current?.href = value }
        case "getcontentlength": current?.size = Int64(value)
        case "getlastmodified": current?.modified = Self.date(value)
        case "response":
            if let c = current, !c.href.isEmpty { entries.append(c) }
            current = nil
        default: break
        }
        text = ""
    }

    private static func date(_ s: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return f.date(from: s)
    }
}
