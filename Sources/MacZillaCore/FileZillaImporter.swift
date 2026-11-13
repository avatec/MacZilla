import Foundation

public struct ImportedSite: Sendable {
    public var site: SiteProfile
    public var password: String?
}

public struct FileZillaImportResult: Sendable {
    public var sites: [ImportedSite] = []
    /// Serwery, których nie da się zaimportować (np. S3, Dropbox) – z powodem.
    public var skipped: [String] = []
    /// Uwagi, które użytkownik powinien znać (np. brak hasła, zmiana szyfrowania).
    public var warnings: [String] = []
    /// Serwery „FTP” z FileZilli próbują TLS, jeśli serwer go oferuje; tu łączą się bez szyfrowania.
    public var opportunisticFTPCount = 0
    public var folderCount: Int { Set(sites.compactMap(\.site.folder)).count }
}

/// Import `sitemanager.xml` z FileZilli (także pliku z funkcji „Eksportuj”).
public enum FileZillaImporter {
    public static var defaultFile: URL {
        URL(fileURLWithPath: NSHomeDirectory() + "/.config/filezilla/sitemanager.xml")
    }

    public static func parse(_ data: Data) throws -> FileZillaImportResult {
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse(), delegate.sawRoot else {
            throw FileProviderError.io("To nie jest plik Menedżera serwerów FileZilli (XML)")
        }
        return delegate.result
    }

    /// `RemoteDir` w FileZilli: `typ prefiks-długość [prefiks] (długość segment)…`, np. `1 0 3 srv 4 www1`.
    static func parseRemoteDir(_ s: String) -> String? {
        let chars = Array(s)
        var i = 0
        func token() -> String? {
            guard i < chars.count else { return nil }
            var t = ""
            while i < chars.count, chars[i] != " " { t.append(chars[i]); i += 1 }
            if i < chars.count { i += 1 }
            return t
        }
        guard let type = token().flatMap({ Int($0) }), [0, 1].contains(type),
              let prefixLen = token().flatMap({ Int($0) }) else { return nil }
        if prefixLen > 0 {
            guard i + prefixLen <= chars.count else { return nil }
            i += prefixLen
            if i < chars.count { i += 1 }
        }
        var segments: [String] = []
        while i < chars.count {
            guard let n = token().flatMap({ Int($0) }), n >= 0, i + n <= chars.count else { return nil }
            segments.append(String(chars[i..<(i + n)]))
            i += n
            if i < chars.count { i += 1 }
        }
        return "/" + segments.joined(separator: "/")
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var result = FileZillaImportResult()
        var sawRoot = false

        private struct Folder { var name: String?; var text = "" }
        private var folders: [Folder] = []
        private var inServer = false
        private var inBookmark = false
        private var field: String?
        private var buffer = ""
        private var fields: [String: String] = [:]
        private var passEncoding: String?

        private func finalizeTopFolder() {
            guard let last = folders.indices.last, folders[last].name == nil else { return }
            let n = folders[last].text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "/", with: "-")
            folders[last].name = n.isEmpty ? "Bez nazwy" : n
        }

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String] = [:]) {
            if name == "FileZilla3" { sawRoot = true }
            if inServer {
                if name == "Bookmark" { inBookmark = true }
                else if !inBookmark { field = name; buffer = ""; if name == "Pass" { passEncoding = attributes["encoding"] } }
                return
            }
            switch name {
            case "Folder": finalizeTopFolder(); folders.append(Folder())
            case "Server": finalizeTopFolder(); inServer = true; fields = [:]; passEncoding = nil
            default: break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if inServer { if field != nil { buffer += string } }
            else if !folders.isEmpty, folders[folders.count - 1].name == nil { folders[folders.count - 1].text += string }
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            if inServer {
                switch name {
                case "Bookmark": inBookmark = false
                case "Server": inServer = false; field = nil; build()
                default:
                    if !inBookmark, field == name { fields[name] = buffer.trimmingCharacters(in: .whitespacesAndNewlines); field = nil }
                }
            } else if name == "Folder" {
                finalizeTopFolder()
                _ = folders.popLast()
            }
        }

        private func build() {
            let f = fields
            let host = f["Host"] ?? ""
            let label = [f["Name"], host].compactMap { $0 }.first { !$0.isEmpty } ?? "?"
            guard !host.isEmpty else { result.skipped.append("\(label): brak hosta"); return }
            let protoCode = Int(f["Protocol"] ?? "0") ?? 0
            var port = Int(f["Port"] ?? "")
            var proto: SiteProtocol
            var siteHost = host
            switch protoCode {
            case 0, 6:
                proto = .ftp
                if protoCode == 0 { result.opportunisticFTPCount += 1 }
            case 1: proto = .sftp
            case 3:
                proto = .ftps
                if let p = port, p != 990 { result.warnings.append("\(label): niejawny FTPS działa w MacZilli tylko na porcie 990 (jest \(p))") }
            case 4: proto = .ftps
            case 2, 5:
                proto = .webdav
                siteHost = (protoCode == 5 ? "https://" : "http://") + host + (port.map { ":\($0)" } ?? "")
                port = nil
            default:
                result.skipped.append("\(label): protokół \(protoCode) nie jest obsługiwany")
                return
            }

            var user = f["User"] ?? ""
            var password: String?
            let logon = Int(f["Logontype"] ?? "1") ?? 1
            switch logon {
            case 0:
                user = "anonymous"; password = "anonymous@"
            case 2, 3:
                break
            default:
                if let raw = f["Pass"], !raw.isEmpty {
                    switch passEncoding {
                    case "base64": password = Data(base64Encoded: raw).map { String(decoding: $0, as: UTF8.self) }
                    case nil: password = raw
                    default: result.warnings.append("\(label): hasło jest chronione hasłem głównym FileZilli – wpisz je ręcznie")
                    }
                }
            }
            if logon == 2 || logon == 3 { result.warnings.append("\(label): FileZilla pytała o hasło przy każdym połączeniu") }

            var site = SiteProfile(
                name: f["Name"].flatMap { $0.isEmpty ? nil : $0 } ?? host, proto: proto, host: siteHost,
                port: port, username: user,
                startPath: f["RemoteDir"].flatMap { FileZillaImporter.parseRemoteDir($0) } ?? "",
                identityFile: logon == 5 ? f["Keyfile"].flatMap { $0.isEmpty ? nil : $0 } : nil,
                authMode: proto == .sftp && logon == 5 ? SFTPAuthMode.key.rawValue : nil)
            let names = folders.compactMap(\.name)
            site.folder = names.isEmpty ? nil : names.joined(separator: "/")
            if let c = f["Comments"], !c.isEmpty { site.notes = c }
            result.sites.append(ImportedSite(site: site, password: password))
        }
    }
}
