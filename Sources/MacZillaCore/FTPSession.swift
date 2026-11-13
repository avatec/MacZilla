import Foundation

public enum FTPSecurity: String, Codable, Sendable {
    case none, explicit, implicit
}

public struct FTPConfig: Sendable {
    public var host: String
    public var port: Int
    public var username: String
    public var password: String
    public var security: FTPSecurity
    public var allowInvalidCertificate: Bool

    public init(host: String, port: Int = 21, username: String = "anonymous", password: String = "anonymous@",
                security: FTPSecurity = .none, allowInvalidCertificate: Bool = false) {
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.security = security
        self.allowInvalidCertificate = allowInvalidCertificate
    }
}

/// Pojedyncze połączenie sterujące FTP. Aktor serializuje komendy.
actor FTPSession {
    private let config: FTPConfig
    private var control: TCPSocket?
    private var supportsMLSD = true
    private var protectData = false
    private var transferCompletionReceived = false
    private(set) var home = "/"

    init(config: FTPConfig) { self.config = config }

    private var peerID: String { "ftps:\(config.host):\(config.port)" }

    func open() throws {
        let s = try TCPSocket(host: config.host, port: config.port)
        control = s
        if config.security == .implicit {
            try s.startTLS(host: config.host, peerID: peerID, allowInvalidCertificate: config.allowInvalidCertificate)
        }
        let hello = try readReply()
        guard hello.code == 220 else { throw FileProviderError.io("Serwer odrzucił połączenie: \(hello.text)") }
        if config.security == .explicit {
            let auth = try command("AUTH TLS")
            guard auth.code == 234 else { throw FileProviderError.io("Serwer nie obsługuje TLS: \(auth.text)") }
            try s.startTLS(host: config.host, peerID: peerID, allowInvalidCertificate: config.allowInvalidCertificate)
        }
        if config.security != .none {
            _ = try command("PBSZ 0")
            let prot = try command("PROT P")
            guard prot.code == 200 else { throw FileProviderError.io("Serwer odrzucił szyfrowanie danych: \(prot.text)") }
            protectData = true
        }
        var r = try command("USER \(config.username)")
        if r.code == 331 { r = try command("PASS \(config.password)") }
        guard r.code == 230 else { throw FileProviderError.io("Logowanie nieudane: \(r.text)") }
        _ = try? command("OPTS UTF8 ON")
        _ = try command("TYPE I")
        let pwd = try command("PWD")
        if pwd.code == 257, let a = pwd.text.firstIndex(of: "\""), let b = pwd.text.lastIndex(of: "\""), a < b {
            home = String(pwd.text[pwd.text.index(after: a)..<b])
        }
    }

    func quit() {
        // QUIT nie czeka na odpowiedź: zamykanie martwej sesji nie może
        // blokować ponownego łączenia przez timeout gniazda.
        if let control { try? control.send(Data("QUIT\r\n".utf8)) }
        close()
    }

    func close() {
        control?.close()
        control = nil
    }

    // MARK: - Sterowanie

    private func readReply() throws -> FTPReply {
        guard let c = control else { throw FileProviderError.notConnected }
        let first = try c.readLine()
        guard first.count >= 3, let code = Int(first.prefix(3)) else { throw FileProviderError.io("Nieprawidłowa odpowiedź: \(first)") }
        var text = String(first.dropFirst(4))
        if first.count > 3, first[first.index(first.startIndex, offsetBy: 3)] == "-" {
            while true {
                let line = try c.readLine()
                text += "\n" + line
                if line.count >= 4, line.hasPrefix(String(code)), line[line.index(line.startIndex, offsetBy: 3)] == " " { break }
            }
        }
        return FTPReply(code: code, text: text)
    }

    @discardableResult
    private func command(_ cmd: String) throws -> FTPReply {
        guard let c = control else { throw FileProviderError.notConnected }
        guard !cmd.contains("\r"), !cmd.contains("\n") else { throw FileProviderError.io("Niedozwolone znaki w komendzie") }
        try c.send(Data((cmd + "\r\n").utf8))
        return try readReply()
    }

    private func expect(_ reply: FTPReply, _ ok: ClosedRange<Int>, path: String) throws {
        guard ok.contains(reply.code) else { throw map(reply, path) }
    }

    private func map(_ r: FTPReply, _ path: String) -> FileProviderError {
        if r.code == 550 || r.code == 450 {
            let t = r.text.lowercased()
            if t.contains("exist") && !t.contains("not exist") && !t.contains("no such") { return .alreadyExists(path) }
            return .notFound(path)
        }
        return .io("\(r.code) \(r.text)")
    }

    private func openData() throws -> TCPSocket {
        let e = try command("EPSV")
        if e.code == 229, let port = FTPParser.epsvPort(e.text) {
            return try TCPSocket(host: config.host, port: port)
        }
        let p = try command("PASV")
        guard p.code == 227, let port = FTPParser.pasvPort(p.text) else { throw FileProviderError.io("PASV nieudane: \(p.text)") }
        // Host sterujący zamiast adresu z odpowiedzi (omija serwery za NAT zwracające adres wewnętrzny).
        return try TCPSocket(host: config.host, port: port)
    }

    private func beginData(_ data: TCPSocket, _ r: FTPReply, _ path: String) throws {
        guard (100...199).contains(r.code) else { data.close(); throw map(r, path) }
        guard protectData else { return }
        do {
            try data.startTLS(host: config.host, peerID: peerID, allowInvalidCertificate: config.allowInvalidCertificate)
        } catch {
            data.close()
            _ = try? readReply()
            throw error
        }
    }

    // MARK: - Operacje

    func list(_ path: String) throws -> [FileItem] {
        if supportsMLSD {
            let data = try openData()
            let r = try command("MLSD \(path)")
            if r.code == 500 || r.code == 501 || r.code == 502 {
                data.close()
                supportsMLSD = false
                return try list(path)
            }
            try beginData(data, r, path)
            let lines = try drainLines(data)
            try expect(try readReply(), 200...299, path: path)
            return lines.compactMap { FTPParser.mlsd($0, parent: path) }
        }
        let data = try openData()
        let r = try command("LIST -a \(path)")
        try beginData(data, r, path)
        let lines = try drainLines(data)
        try expect(try readReply(), 200...299, path: path)
        return lines.compactMap { FTPParser.unixList($0, parent: path) }
    }

    private func drainLines(_ data: TCPSocket) throws -> [String] {
        var all = Data()
        while let chunk = try data.receive() { all.append(chunk) }
        data.close()
        return String(decoding: all, as: UTF8.self)
            .split(whereSeparator: { $0 == "\n" || $0 == "\r\n" })
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\r")) }
            .filter { !$0.isEmpty }
    }

    func retrieve(_ path: String, offset: Int64, onChunk: @Sendable (Data) -> Void) throws {
        let data = try openData()
        if offset > 0 {
            let rest = try command("REST \(offset)")
            guard rest.code == 350 else { data.close(); throw FileProviderError.unsupported("Wznawianie: \(rest.text)") }
        }
        let r = try command("RETR \(path)")
        try beginData(data, r, path)
        while let chunk = try data.receive() {
            if Task.isCancelled { data.close(); _ = try? readReply(); throw CancellationError() }
            onChunk(chunk)
        }
        data.close()
        try expect(try readReply(), 200...299, path: path)
    }

    func store(_ path: String, from stream: AsyncThrowingStream<Data, Error>, offset: Int64) async throws {
        let data = try openData()
        if offset > 0 {
            let rest = try command("REST \(offset)")
            guard rest.code == 350 else { data.close(); throw FileProviderError.unsupported("Wznawianie: \(rest.text)") }
        }
        let r = try command("STOR \(path)")
        try beginData(data, r, path)
        transferCompletionReceived = false
        let keepAlive = Task.detached { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(15)) }
                catch { return }
                guard !Task.isCancelled, let self else { return }
                do { try await self.keepAliveDuringTransfer() }
                catch { return }
            }
        }
        do {
            for try await chunk in stream { try data.send(chunk) }
            data.close()
            keepAlive.cancel()
            await keepAlive.value
            if !transferCompletionReceived { try expect(try readReply(), 200...299, path: path) }
            transferCompletionReceived = false
        } catch {
            data.close()
            keepAlive.cancel()
            await keepAlive.value
            _ = try? readReply()
            transferCompletionReceived = false
            throw error
        }
    }

    private func keepAliveDuringTransfer() throws {
        let reply = try command("NOOP")
        if reply.code == 226 {
            // Niektóre serwery wysyłają końcowe 226 przed odpowiedzią na NOOP.
            transferCompletionReceived = true
            try expect(try readReply(), 200...299, path: "")
        } else {
            try expect(reply, 200...299, path: "")
        }
    }

    func simple(_ cmd: String, path: String, ok: ClosedRange<Int> = 200...299) throws {
        try expect(try command(cmd), ok, path: path)
    }

    func rename(_ from: String, to: String) throws {
        try expect(try command("RNFR \(from)"), 350...350, path: from)
        try expect(try command("RNTO \(to)"), 200...299, path: to)
    }

    func checkConnection() throws {
        try expect(try command("NOOP"), 200...299, path: "")
    }

    func setPermissions(_ path: String, mode: UInt16) throws {
        let value = String(mode & 0o7777, radix: 8)
        try simple("SITE CHMOD \(value) \(path)", path: path)
    }
}
