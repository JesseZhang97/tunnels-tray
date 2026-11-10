import Foundation

/// Minimal POSIX-shell-style word splitting and quoting.
public enum ShellWords {
    public enum SplitError: Error, Equatable, CustomStringConvertible {
        case unclosedQuote(Character)
        case trailingBackslash

        public var description: String {
            switch self {
            case .unclosedQuote(let q): return "unclosed \(q) quote"
            case .trailingBackslash: return "trailing backslash"
            }
        }
    }

    public static func split(_ input: String) throws -> [String] {
        let chars = Array(input)
        var words: [String] = []
        var current = ""
        var inWord = false
        var quote: Character?
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if let q = quote {
                if c == q {
                    quote = nil
                } else if q == "\"", c == "\\", i + 1 < chars.count, "\"\\$`".contains(chars[i + 1]) {
                    current.append(chars[i + 1])
                    i += 1
                } else {
                    current.append(c)
                }
            } else if c == "'" || c == "\"" {
                quote = c
                inWord = true
            } else if c == "\\" {
                guard i + 1 < chars.count else { throw SplitError.trailingBackslash }
                current.append(chars[i + 1])
                inWord = true
                i += 1
            } else if c.isWhitespace {
                if inWord {
                    words.append(current)
                    current = ""
                    inWord = false
                }
            } else {
                current.append(c)
                inWord = true
            }
            i += 1
        }
        if let q = quote { throw SplitError.unclosedQuote(q) }
        if inWord { words.append(current) }
        return words
    }

    private static let safe = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_./:=@,+%[]")

    /// Quote one word so a shell reads it back unchanged.
    public static func quote(_ word: String) -> String {
        if word.isEmpty { return "''" }
        if word.unicodeScalars.allSatisfy({ safe.contains($0) }) { return word }
        return "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    public static func join(_ words: [String]) -> String {
        words.map(quote).joined(separator: " ")
    }
}
