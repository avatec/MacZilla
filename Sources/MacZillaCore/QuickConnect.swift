import Foundation

/// Szybkie połączenie: `sftp://user:haslo@host:2222/sciezka`, `user@host:port` albo samo `host`.
public enum QuickConnect {
    public static func parse(_ input: String, defaultProtocol: SiteProtocol = .sftp) -> (site: SiteProfile, password: String)? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if text.contains("://") { return parseURL(text) }

        var rest = text
        var path = ""
        if let slash = rest.firstIndex(of: "/") { path = String(rest[slash...]); rest = String(rest[..<slash]) }
        var user = "", pass = ""
        if let at = rest.lastIndex(of: "@") {
            let cred = rest[..<at]
            rest = String(rest[rest.index(after: at)...])
            if let colon = cred.firstIndex(of: ":") {
                user = String(cred[..<colon]); pass = String(cred[cred.index(after: colon)...])
            } else { user = String(cred) }
        }
        var host = rest
        var port: Int?
        if let colon = rest.lastIndex(of: ":"), let p = Int(rest[rest.index(after: colon)...]), (1...65535).contains(p) {
            host = String(rest[..<colon]); port = p
        }
        return make(proto: defaultProtocol, host: host, port: port, user: user, pass: pass, path: path)
    }

    private static func parseURL(_ text: String) -> (site: SiteProfile, password: String)? {
        guard let c = URLComponents(string: text), let scheme = c.scheme?.lowercased(), let host = c.host else { return nil }
        let user = c.percentEncodedUser ?? "", pass = c.percentEncodedPassword ?? ""
        switch scheme {
        case "ftp": return make(proto: .ftp, host: host, port: c.port, user: user, pass: pass, path: c.path)
        case "ftpes": return make(proto: .ftps, host: host, port: c.port ?? 21, user: user, pass: pass, path: c.path)
        case "ftps": return make(proto: .ftps, host: host, port: c.port ?? 990, user: user, pass: pass, path: c.path)
        case "sftp", "ssh": return make(proto: .sftp, host: host, port: c.port, user: user, pass: pass, path: c.path)
        case "http", "https", "webdav", "webdavs":
            let secure = scheme == "https" || scheme == "webdavs"
            var base = (secure ? "https://" : "http://") + host
            if let p = c.port { base += ":\(p)" }
            base += c.path
            return make(proto: .webdav, host: base, port: nil, user: user, pass: pass, path: "", name: host)
        default: return nil
        }
    }

    private static func make(proto: SiteProtocol, host: String, port: Int?, user: String, pass: String,
                             path: String, name: String? = nil) -> (site: SiteProfile, password: String)? {
        guard !host.isEmpty, !host.hasPrefix("-"), !host.contains(" ") else { return nil }
        let site = SiteProfile(name: name ?? host, proto: proto, host: host, port: port,
                               username: user.removingPercentEncoding ?? user,
                               startPath: path == "/" ? "" : path)
        return (site, pass.removingPercentEncoding ?? pass)
    }
}
