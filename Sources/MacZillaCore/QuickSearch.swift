import Foundation

/// Wyszukiwanie „type-ahead” w liście plików: bufor znaków resetowany po przerwie,
/// dopasowanie po prefiksie (bez rozróżniania wielkości liter i znaków diakrytycznych).
public struct QuickSearch: Sendable {
    public private(set) var buffer = ""
    private var lastInput: Date = .distantPast
    public var timeout: TimeInterval

    public init(timeout: TimeInterval = 1.0) { self.timeout = timeout }

    public mutating func append(_ text: String, now: Date = Date()) {
        if now.timeIntervalSince(lastInput) > timeout { buffer = "" }
        buffer += text
        lastInput = now
    }

    public mutating func reset() { buffer = "" }

    public func isActive(now: Date = Date()) -> Bool {
        !buffer.isEmpty && now.timeIntervalSince(lastInput) <= timeout
    }

    /// Indeks pierwszego pasującego elementu; szukanie zaczyna się od `from`, aby powtarzanie
    /// tej samej litery przechodziło po kolejnych dopasowaniach.
    public func match(in names: [String], from start: Int = 0) -> Int? {
        guard !buffer.isEmpty, !names.isEmpty else { return nil }
        let opts: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        let n = names.count
        for offset in 0..<n {
            let i = (start + offset) % n
            if names[i].range(of: buffer, options: opts.union(.anchored)) != nil { return i }
        }
        return nil
    }

    /// Dopasowanie nazwy do wzorca z `*` i `?` (zaznaczanie grupy plików, np. `*.txt`).
    public static func glob(_ pattern: String, matches name: String) -> Bool {
        var regex = "^"
        for ch in pattern {
            switch ch {
            case "*": regex += ".*"
            case "?": regex += "."
            default: regex += NSRegularExpression.escapedPattern(for: String(ch))
            }
        }
        regex += "$"
        return name.range(of: regex, options: [.regularExpression, .caseInsensitive]) != nil
    }
}
