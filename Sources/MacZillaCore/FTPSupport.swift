import Foundation
import Darwin

/// Prosty, blokujący gniazdo TCP (używane wyłącznie wewnątrz aktora `FTPSession`).
final class TCPSocket {
    private var fd: Int32
    private var buffer = Data()

    init(host: String, port: Int, timeout: Int = 30) throws {
        var hints = addrinfo()
        hints.ai_socktype = SOCK_STREAM
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &res) == 0, let first = res else {
            throw FileProviderError.io("Nie można zresolwować hosta \(host)")
        }
        defer { freeaddrinfo(res) }
        var found: Int32 = -1
        var ptr: UnsafeMutablePointer<addrinfo>? = first
        while let ai = ptr {
            let s = socket(ai.pointee.ai_family, ai.pointee.ai_socktype, ai.pointee.ai_protocol)
            if s >= 0 {
                var tv = timeval(tv_sec: timeout, tv_usec: 0)
                setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
                setsockopt(s, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
                var one: Int32 = 1
                setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
                if Darwin.connect(s, ai.pointee.ai_addr, ai.pointee.ai_addrlen) == 0 { found = s; break }
                Darwin.close(s)
            }
            ptr = ai.pointee.ai_next
        }
        guard found >= 0 else { throw FileProviderError.io("Nie można połączyć z \(host):\(port)") }
        fd = found
    }

    deinit { close() }

    func close() {
        if let ctx = ssl {
            SSLClose(ctx)
            ssl = nil
        }
        if fd >= 0 { Darwin.close(fd); fd = -1 }
    }

    private var ssl: SSLContext?

    /// Przełącza istniejące połączenie na TLS (SecureTransport, działa na blokującym gnieździe).
    /// `peerID` pozwala wznowić sesję TLS na kanale danych (wymagane przez część serwerów).
    func startTLS(host: String, peerID: String, allowInvalidCertificate: Bool) throws {
        guard ssl == nil, buffer.isEmpty else { throw FileProviderError.io("Nieprawidłowy stan TLS") }
        guard let ctx = SSLCreateContext(nil, .clientSide, .streamType) else { throw FileProviderError.io("TLS: brak kontekstu") }
        SSLSetIOFuncs(ctx, { conn, data, len in
            Unmanaged<TCPSocket>.fromOpaque(conn).takeUnretainedValue().sslRead(data, len)
        }, { conn, data, len in
            Unmanaged<TCPSocket>.fromOpaque(conn).takeUnretainedValue().sslWrite(data, len)
        })
        SSLSetConnection(ctx, Unmanaged.passUnretained(self).toOpaque())
        SSLSetPeerID(ctx, peerID, peerID.utf8.count)
        if allowInvalidCertificate {
            SSLSetSessionOption(ctx, .breakOnServerAuth, true)
        } else {
            SSLSetPeerDomainName(ctx, host, host.utf8.count)
        }
        var status = SSLHandshake(ctx)
        while status == errSSLPeerAuthCompleted { status = SSLHandshake(ctx) }
        guard status == noErr else {
            SSLClose(ctx)
            let msg = SecCopyErrorMessageString(status, nil) as String? ?? "kod \(status)"
            throw FileProviderError.io("Błąd TLS: \(msg)")
        }
        ssl = ctx
    }

    var isEncrypted: Bool { ssl != nil }

    private func sslRead(_ data: UnsafeMutableRawPointer, _ len: UnsafeMutablePointer<Int>) -> OSStatus {
        let wanted = len.pointee
        var done = 0
        var status: OSStatus = noErr
        while done < wanted {
            let n = Darwin.read(fd, data + done, wanted - done)
            if n > 0 { done += n; continue }
            if n == 0 { status = errSSLClosedGraceful }
            else if errno == EAGAIN || errno == EWOULDBLOCK { status = errSSLWouldBlock }
            else if errno == ECONNRESET { status = errSSLClosedAbort }
            else { status = errSecIO }
            break
        }
        len.pointee = done
        return status
    }

    private func sslWrite(_ data: UnsafeRawPointer, _ len: UnsafeMutablePointer<Int>) -> OSStatus {
        let wanted = len.pointee
        var done = 0
        var status: OSStatus = noErr
        while done < wanted {
            let n = Darwin.write(fd, data + done, wanted - done)
            if n > 0 { done += n; continue }
            if n < 0, errno == EAGAIN || errno == EWOULDBLOCK { status = errSSLWouldBlock }
            else if n < 0, errno == EPIPE || errno == ECONNRESET { status = errSSLClosedAbort }
            else { status = errSecIO }
            break
        }
        len.pointee = done
        return status
    }

    /// Zwraca liczbę bajtów, 0 przy zamknięciu połączenia, -1 przy błędzie/timeout.
    private func rawRead(_ buf: UnsafeMutableRawPointer, _ n: Int) -> Int {
        guard let ctx = ssl else { return Darwin.recv(fd, buf, n, 0) }
        var processed = 0
        let status = SSLRead(ctx, buf, n, &processed)
        switch status {
        case noErr: return processed
        case errSSLWouldBlock: return processed > 0 ? processed : -1
        case errSSLClosedGraceful, errSSLClosedAbort: return processed
        default: return processed > 0 ? processed : -1
        }
    }

    func send(_ data: Data) throws {
        var sent = 0
        try data.withUnsafeBytes { raw in
            while sent < data.count {
                let n: Int
                if let ctx = ssl {
                    var processed = 0
                    let st = SSLWrite(ctx, raw.baseAddress! + sent, data.count - sent, &processed)
                    n = (st == noErr || st == errSSLWouldBlock) ? processed : -1
                } else {
                    n = Darwin.send(fd, raw.baseAddress! + sent, data.count - sent, 0)
                }
                if n <= 0 { throw FileProviderError.io("Błąd zapisu do gniazda") }
                sent += n
            }
        }
    }

    /// Zwraca nil po zamknięciu połączenia przez drugą stronę.
    func receive(max: Int = 256 * 1024) throws -> Data? {
        if !buffer.isEmpty {
            let n = min(max, buffer.count)
            defer { buffer.removeFirst(n) }
            return buffer.prefix(n)
        }
        var chunk = [UInt8](repeating: 0, count: max)
        let n = rawRead(&chunk, max)
        if n < 0 { throw FileProviderError.io("Przekroczono czas oczekiwania lub błąd odczytu") }
        return n == 0 ? nil : Data(chunk[0..<n])
    }

    func readLine() throws -> String {
        while true {
            if let idx = buffer.firstIndex(of: 0x0A) {
                var line = buffer[buffer.startIndex..<idx]
                buffer.removeSubrange(buffer.startIndex...idx)
                if line.last == 0x0D { line = line.dropLast() }
                return String(decoding: line, as: UTF8.self)
            }
            var chunk = [UInt8](repeating: 0, count: 4096)
            let n = rawRead(&chunk, chunk.count)
            if n <= 0 { throw FileProviderError.io("Połączenie zostało zamknięte") }
            buffer.append(contentsOf: chunk[0..<n])
        }
    }
}

struct FTPReply {
    let code: Int
    let text: String
}

enum FTPParser {
    static func mlsd(_ line: String, parent: String) -> FileItem? {
        guard let space = line.firstIndex(of: " ") else { return nil }
        let facts = line[..<space]
        let name = String(line[line.index(after: space)...])
        guard name != ".", name != ".." else { return nil }
        var dict: [String: String] = [:]
        for f in facts.split(separator: ";") {
            if let eq = f.firstIndex(of: "=") {
                dict[f[..<eq].lowercased()] = String(f[f.index(after: eq)...])
            }
        }
        let type = dict["type"]?.lowercased() ?? "file"
        let kind: FileKind
        switch type {
        case "file": kind = .file
        case "dir": kind = .directory
        case "cdir", "pdir": return nil
        case _ where type.contains("slink"): kind = .symlink
        default: kind = .other
        }
        var perms: UInt16?
        if let m = dict["unix.mode"], let v = UInt16(m, radix: 8) { perms = v & 0o7777 }
        return FileItem(
            name: name, path: PathUtil.join(parent, name), kind: kind,
            size: dict["size"].flatMap { Int64($0) }, modified: dict["modify"].flatMap(parseTime),
            permissions: perms, isHidden: name.hasPrefix("."))
    }

    static func parseTime(_ s: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = s.contains(".") ? "yyyyMMddHHmmss.SSS" : "yyyyMMddHHmmss"
        return f.date(from: s)
    }

    /// Format `ls -l`: "drwxr-xr-x 2 user group 4096 Jan  1 12:00 name".
    static func unixList(_ line: String, parent: String) -> FileItem? {
        let parts = line.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: true)
        guard parts.count >= 9, let first = parts[0].first, "-dlbcps".contains(first) else { return nil }
        var name = String(parts[8])
        if first == "l", let r = name.range(of: " -> ") { name = String(name[..<r.lowerBound]) }
        guard name != ".", name != ".." else { return nil }
        let kind: FileKind = first == "d" ? .directory : first == "l" ? .symlink : first == "-" ? .file : .other
        return FileItem(
            name: name, path: PathUtil.join(parent, name), kind: kind,
            size: Int64(parts[4]), modified: nil, permissions: mode(String(parts[0])),
            isHidden: name.hasPrefix("."))
    }

    static func mode(_ s: String) -> UInt16? {
        let chars = Array(s.dropFirst())
        guard chars.count >= 9 else { return nil }
        var m: UInt16 = 0
        for i in 0..<9 where chars[i] != "-" { m |= 1 << UInt16(8 - i) }
        return m
    }

    static func pasvPort(_ text: String) -> Int? {
        guard let open = text.lastIndex(of: "("), let close = text.lastIndex(of: ")"), open < close else { return nil }
        let nums = text[text.index(after: open)..<close].split(separator: ",").compactMap { Int($0) }
        guard nums.count == 6 else { return nil }
        return nums[4] * 256 + nums[5]
    }

    static func epsvPort(_ text: String) -> Int? {
        guard let open = text.lastIndex(of: "("), let close = text.lastIndex(of: ")"), open < close else { return nil }
        let inner = text[text.index(after: open)..<close]
        let fields = inner.split(separator: "|", omittingEmptySubsequences: false)
        return fields.compactMap { Int($0) }.last
    }
}
