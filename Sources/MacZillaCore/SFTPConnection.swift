import Foundation
import Darwin

struct ByteWriter {
    var bytes: [UInt8] = []
    mutating func u8(_ v: UInt8) { bytes.append(v) }
    mutating func u32(_ v: UInt32) { bytes.append(contentsOf: withUnsafeBytes(of: v.bigEndian, Array.init)) }
    mutating func u64(_ v: UInt64) { bytes.append(contentsOf: withUnsafeBytes(of: v.bigEndian, Array.init)) }
    mutating func raw(_ b: [UInt8]) { u32(UInt32(b.count)); bytes.append(contentsOf: b) }
    mutating func string(_ s: String) { raw(Array(s.utf8)) }
}

struct ByteReader {
    let bytes: [UInt8]
    var pos = 0
    init(_ b: [UInt8]) { bytes = b }

    private mutating func take(_ n: Int) throws -> ArraySlice<UInt8> {
        guard n >= 0, pos + n <= bytes.count else { throw FileProviderError.io("Uszkodzona odpowiedź SFTP") }
        defer { pos += n }
        return bytes[pos..<pos + n]
    }
    mutating func u8() throws -> UInt8 { try take(1).first! }
    mutating func u32() throws -> UInt32 { try take(4).reduce(0) { $0 << 8 | UInt32($1) } }
    mutating func u64() throws -> UInt64 { try take(8).reduce(0) { $0 << 8 | UInt64($1) } }
    mutating func raw() throws -> [UInt8] { Array(try take(Int(try u32()))) }
    mutating func string() throws -> String { String(decoding: try raw(), as: UTF8.self) }
}

struct SFTPAttrs {
    var size: Int64?
    var mode: UInt32?
    var mtime: UInt32?

    static func read(_ r: inout ByteReader) throws -> SFTPAttrs {
        var a = SFTPAttrs()
        let flags = try r.u32()
        if flags & 0x1 != 0 { a.size = Int64(clamping: try r.u64()) }
        if flags & 0x2 != 0 { _ = try r.u32(); _ = try r.u32() }
        if flags & 0x4 != 0 { a.mode = try r.u32() }
        if flags & 0x8 != 0 { _ = try r.u32(); a.mtime = try r.u32() }
        if flags & 0x8000_0000 != 0 {
            for _ in 0..<(try r.u32()) { _ = try r.raw(); _ = try r.raw() }
        }
        return a
    }

    var kind: FileKind {
        switch (mode ?? 0) & 0o170000 {
        case 0o040000: return .directory
        case 0o100000: return .file
        case 0o120000: return .symlink
        default: return .other
        }
    }
}

/// Blokujące połączenie SFTP v3 przez podproces `ssh -s sftp`. Wszystkie wywołania muszą iść przez `queue`.
final class SFTPConnection: @unchecked Sendable {
    let queue = DispatchQueue(label: "maczilla.sftp")
    private let process = Process()
    private let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
    private let errLock = NSLock()
    private var errTail = Data()
    private var nextID: UInt32 = 1
    private var askpass: URL?
    private let chunk = 32 * 1024

    init(config: SFTPConfig) throws {
        guard !config.host.hasPrefix("-"), !config.host.isEmpty, !config.username.hasPrefix("-") else {
            throw FileProviderError.io("Nieprawidłowy host lub użytkownik")
        }
        signal(SIGPIPE, SIG_IGN)
        var args = ["-s", "-p", String(config.port), "-o", "ConnectTimeout=15",
                    "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=4",
                    "-o", "StrictHostKeyChecking=\(config.strictHostKeys ? "yes" : "accept-new")", "-o", "LogLevel=ERROR"]
        var env = ProcessInfo.processInfo.environment
        switch config.authMode {
        case .password:
            guard !config.password.isEmpty else { throw FileProviderError.io("Tryb „Hasło”: podaj hasło") }
            args += ["-o", "PreferredAuthentications=password,keyboard-interactive", "-o", "PubkeyAuthentication=no"]
        case .key:
            guard config.identityFile != nil else { throw FileProviderError.io("Tryb „Plik klucza”: wybierz plik klucza") }
            args += ["-o", "PreferredAuthentications=publickey"]
        case .agent:
            args += ["-o", "PreferredAuthentications=publickey"]
        case .auto:
            break
        }
        let usePassword = !config.password.isEmpty && config.authMode != .agent
        if !usePassword {
            args += ["-o", "BatchMode=yes"]
        } else {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("mz-askpass-\(UUID().uuidString)")
            try "#!/bin/sh\nprintf '%s\\n' \"$MZ_SSH_PW\"\n".write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
            askpass = url
            env["SSH_ASKPASS"] = url.path
            env["SSH_ASKPASS_REQUIRE"] = "force"
            env["MZ_SSH_PW"] = config.password
            env["DISPLAY"] = env["DISPLAY"] ?? ":0"
            args += ["-o", "NumberOfPasswordPrompts=1"]
        }
        if config.authMode != .password, config.authMode != .agent, let key = config.identityFile { args += ["-i", key, "-o", "IdentitiesOnly=yes"] }
        args += config.extraOptions
        args += ["-l", config.username, "--", config.host, "sftp"]

        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = args
        process.environment = env
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        stderr.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard let self, !d.isEmpty else { h.readabilityHandler = nil; return }
            self.errLock.withLock { self.errTail = Data((self.errTail + d).suffix(2048)) }
        }
        try process.run()
    }

    deinit { shutdown() }

    func shutdown() {
        stderr.fileHandleForReading.readabilityHandler = nil
        try? stdin.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
        if let a = askpass { try? FileManager.default.removeItem(at: a); askpass = nil }
    }

    private var errText: String {
        errLock.withLock { String(decoding: errTail, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    // MARK: - Pakiety

    private func sendPacket(_ body: [UInt8]) throws {
        var w = ByteWriter()
        w.u32(UInt32(body.count))
        let data = w.bytes + body
        let fd = stdin.fileHandleForWriting.fileDescriptor
        var sent = 0
        try data.withUnsafeBytes { raw in
            while sent < data.count {
                let n = Darwin.write(fd, raw.baseAddress! + sent, data.count - sent)
                if n <= 0 { throw closedError() }
                sent += n
            }
        }
    }

    private func readExactly(_ n: Int) throws -> [UInt8] {
        let fd = stdout.fileHandleForReading.fileDescriptor
        var out = [UInt8](repeating: 0, count: n)
        var got = 0
        while got < n {
            let r = out.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress! + got, n - got) }
            if r <= 0 { throw closedError() }
            got += r
        }
        return out
    }

    private func closedError() -> FileProviderError {
        Thread.sleep(forTimeInterval: 0.1)
        let e = errText
        return .io(e.isEmpty ? "Połączenie SSH zostało zamknięte" : e)
    }

    private func receivePacket() throws -> (UInt8, ByteReader) {
        var h = ByteReader(try readExactly(4))
        let len = Int(try h.u32())
        guard len >= 1, len <= 4 * 1024 * 1024 else { throw FileProviderError.io("Nieprawidłowy pakiet SFTP") }
        var r = ByteReader(try readExactly(len))
        return (try r.u8(), r)
    }

    func handshake() throws {
        var w = ByteWriter()
        w.u8(1); w.u32(3)
        try sendPacket(w.bytes)
        let (t, _) = try receivePacket()
        guard t == 2 else { throw FileProviderError.io("Serwer nie obsługuje SFTP") }
    }

    private func exchange(_ type: UInt8, _ body: (inout ByteWriter) -> Void) throws -> (UInt8, ByteReader) {
        let id = nextID
        nextID &+= 1
        var w = ByteWriter()
        w.u8(type); w.u32(id)
        body(&w)
        try sendPacket(w.bytes)
        var (t, r) = try receivePacket()
        guard try r.u32() == id else { throw FileProviderError.io("Rozsynchronizowana odpowiedź SFTP") }
        return (t, r)
    }

    private func statusError(_ r: inout ByteReader, _ path: String) throws -> FileProviderError? {
        let code = try r.u32()
        let msg = (try? r.string()) ?? ""
        switch code {
        case 0: return nil
        case 2: return .notFound(path)
        case 3: return .io("Brak uprawnień: \(path)")
        default: return .io(msg.isEmpty ? "Błąd SFTP (\(code))" : msg)
        }
    }

    private func expectOK(_ t: UInt8, _ r: ByteReader, _ path: String) throws {
        guard t == 101 else { throw FileProviderError.io("Nieoczekiwana odpowiedź SFTP (\(t))") }
        var r = r
        if let e = try statusError(&r, path) { throw e }
    }

    private func handle(_ t: UInt8, _ r: ByteReader, _ path: String) throws -> [UInt8] {
        var r = r
        if t == 101 { throw try statusError(&r, path) ?? FileProviderError.io("Brak uchwytu") }
        guard t == 102 else { throw FileProviderError.io("Nieoczekiwana odpowiedź SFTP (\(t))") }
        return try r.raw()
    }

    // MARK: - Operacje

    func realpath(_ path: String) throws -> String {
        var (t, r) = try exchange(16) { $0.string(path) }
        if t == 101 { throw try statusError(&r, path) ?? FileProviderError.io("realpath") }
        guard t == 104, try r.u32() >= 1 else { throw FileProviderError.io("Nieoczekiwana odpowiedź SFTP") }
        return try r.string()
    }

    func stat(_ path: String, follow: Bool = true) throws -> SFTPAttrs {
        var (t, r) = try exchange(follow ? 17 : 7) { $0.string(path) }
        if t == 101 { throw try statusError(&r, path) ?? FileProviderError.io("stat") }
        guard t == 105 else { throw FileProviderError.io("Nieoczekiwana odpowiedź SFTP (\(t))") }
        return try SFTPAttrs.read(&r)
    }

    func listDir(_ path: String) throws -> [(String, SFTPAttrs)] {
        let (ot, orr) = try exchange(11) { $0.string(path) }
        let h = try handle(ot, orr, path)
        defer { _ = try? exchange(4) { $0.raw(h) } }
        var out: [(String, SFTPAttrs)] = []
        while true {
            var (t, r) = try exchange(12) { $0.raw(h) }
            if t == 101 {
                let code = try r.u32()
                if code == 1 { break }
                throw FileProviderError.io((try? r.string()) ?? "Błąd listowania SFTP (\(code))")
            }
            guard t == 104 else { throw FileProviderError.io("Nieoczekiwana odpowiedź SFTP (\(t))") }
            let count = try r.u32()
            for _ in 0..<count {
                let name = try r.string()
                _ = try r.string()
                let attrs = try SFTPAttrs.read(&r)
                if name != "." && name != ".." { out.append((name, attrs)) }
            }
        }
        return out
    }

    func open(_ path: String, flags: UInt32) throws -> [UInt8] {
        let (t, r) = try exchange(3) { $0.string(path); $0.u32(flags); $0.u32(0) }
        return try handle(t, r, path)
    }

    func close(_ h: [UInt8]) { _ = try? exchange(4) { $0.raw(h) } }

    func read(_ h: [UInt8], offset: Int64, path: String) throws -> Data? {
        var (t, r) = try exchange(5) { $0.raw(h); $0.u64(UInt64(offset)); $0.u32(UInt32(chunk)) }
        if t == 101 {
            let code = try r.u32()
            if code == 1 { return nil }
            throw code == 2 ? FileProviderError.notFound(path) : FileProviderError.io((try? r.string()) ?? "Błąd odczytu (\(code))")
        }
        guard t == 103 else { throw FileProviderError.io("Nieoczekiwana odpowiedź SFTP (\(t))") }
        return Data(try r.raw())
    }

    func write(_ h: [UInt8], offset: Int64, data: Data, path: String) throws {
        var pos = 0
        while pos < data.count {
            let part = Array(data[data.startIndex + pos ..< data.startIndex + min(pos + chunk, data.count)])
            let (t, r) = try exchange(6) { $0.raw(h); $0.u64(UInt64(offset) + UInt64(pos)); $0.raw(part) }
            try expectOK(t, r, path)
            pos += part.count
        }
    }

    func simple(_ type: UInt8, _ path: String, extra: ((inout ByteWriter) -> Void)? = nil) throws {
        let (t, r) = try exchange(type) { $0.string(path); extra?(&$0) }
        try expectOK(t, r, path)
    }

    func rename(_ from: String, to: String) throws {
        let (t, r) = try exchange(18) { $0.string(from); $0.string(to) }
        try expectOK(t, r, from)
    }

    func setPermissions(_ path: String, mode: UInt16) throws {
        // SSH_FXP_SETSTAT z atrybutem SSH_FILEXFER_ATTR_PERMISSIONS.
        let (t, r) = try exchange(9) { w in
            w.string(path)
            w.u32(0x4)
            w.u32(UInt32(mode & 0o7777))
        }
        try expectOK(t, r, path)
    }
}
