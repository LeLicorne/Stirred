import Foundation

/// Minimal parser for Valve's text KeyValues format (`libraryfolders.vdf`, `appmanifest_*.acf`).
public indirect enum VDFValue: Equatable, Sendable {
    case string(String)
    case object([String: VDFValue])

    public subscript(key: String) -> VDFValue? {
        if case .object(let dict) = self { return dict[key] }
        return nil
    }

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }
}

public enum VDFError: Error, Sendable {
    case unexpectedEnd
    case unexpectedToken(String)
}

public enum VDF {
    /// Parses a document into its top-level key/value map.
    public static func parse(_ text: String) throws -> [String: VDFValue] {
        var tokens = try tokenize(text)[...]
        var result: [String: VDFValue] = [:]
        while !tokens.isEmpty {
            let key = try expectString(&tokens)
            result[key] = try parseValue(&tokens)
        }
        return result
    }

    private enum Token: Equatable {
        case string(String), open, close
    }

    private static func tokenize(_ text: String) throws -> [Token] {
        var tokens: [Token] = []
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            switch c {
            case " ", "\t", "\n", "\r":
                i += 1
            case "/" where i + 1 < chars.count && chars[i + 1] == "/":
                while i < chars.count && chars[i] != "\n" { i += 1 }
            case "{":
                tokens.append(.open); i += 1
            case "}":
                tokens.append(.close); i += 1
            case "\"":
                i += 1
                var value = ""
                var closed = false
                while i < chars.count {
                    let d = chars[i]
                    if d == "\\", i + 1 < chars.count {
                        let next = chars[i + 1]
                        switch next {
                        case "n": value.append("\n")
                        case "t": value.append("\t")
                        default: value.append(next)
                        }
                        i += 2
                    } else if d == "\"" {
                        closed = true; i += 1; break
                    } else {
                        value.append(d); i += 1
                    }
                }
                if !closed { throw VDFError.unexpectedEnd }
                tokens.append(.string(value))
            default:
                throw VDFError.unexpectedToken(String(c))
            }
        }
        return tokens
    }

    private static func expectString(_ tokens: inout ArraySlice<Token>) throws -> String {
        guard let first = tokens.popFirst() else { throw VDFError.unexpectedEnd }
        guard case .string(let s) = first else { throw VDFError.unexpectedToken("\(first)") }
        return s
    }

    private static func parseValue(_ tokens: inout ArraySlice<Token>) throws -> VDFValue {
        guard let first = tokens.popFirst() else { throw VDFError.unexpectedEnd }
        switch first {
        case .string(let s):
            return .string(s)
        case .open:
            var dict: [String: VDFValue] = [:]
            while true {
                guard let next = tokens.first else { throw VDFError.unexpectedEnd }
                if next == .close { tokens.removeFirst(); return .object(dict) }
                let key = try expectString(&tokens)
                dict[key] = try parseValue(&tokens)
            }
        case .close:
            throw VDFError.unexpectedToken("}")
        }
    }
}
