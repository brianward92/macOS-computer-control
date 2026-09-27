import Foundation

/// The option parser shared by the CLI and its tests.
///
/// Strict on purpose. A flag the command does not know is an error, not
/// something to skip past: `--cont 2` silently ignored is a single click that
/// looks like a double click that did not take, and that is indistinguishable
/// from the app being in the wrong state.
///
/// Only `--name` tokens are flags, so a negative number (`scroll App 0.5 0.5
/// -3`) stays positional, and everything after a bare `--` is positional
/// whatever it looks like.
public struct Arguments: Sendable, Equatable {

    /// A flag a command accepts. `takesValue` flags consume the next token, or
    /// an inline `--name=value`.
    public struct Option: Sendable, Equatable {
        public let name: String
        public let takesValue: Bool
        public init(_ name: String, takesValue: Bool = false) {
            self.name = name
            self.takesValue = takesValue
        }
    }

    public enum ParseError: Error, CustomStringConvertible, Equatable {
        case unknownFlag(String)
        case missingValue(String)
        case unexpectedValue(String)

        public var description: String {
            switch self {
            case .unknownFlag(let f): return "unknown flag: \(f)"
            case .missingValue(let f): return "--\(f) needs a value"
            case .unexpectedValue(let f): return "--\(f) does not take a value"
            }
        }
    }

    public let positionals: [String]
    public let values: [String: String]
    public let flags: Set<String>

    public init(positionals: [String] = [], values: [String: String] = [:], flags: Set<String> = []) {
        self.positionals = positionals
        self.values = values
        self.flags = flags
    }

    public static func parse(_ argv: [String], accepting options: [Option]) throws -> Arguments {
        var positionals: [String] = []
        var values: [String: String] = [:]
        var flags: Set<String> = []
        var index = 0
        var literal = false
        while index < argv.count {
            let token = argv[index]
            index += 1
            if literal || !token.hasPrefix("--") {
                positionals.append(token)
                continue
            }
            if token == "--" {
                literal = true
                continue
            }
            let body = token.dropFirst(2)
            let name: String
            var inline: String?
            if let equals = body.firstIndex(of: "=") {
                name = String(body[..<equals])
                inline = String(body[body.index(after: equals)...])
            } else {
                name = String(body)
            }
            guard let option = options.first(where: { $0.name == name }) else {
                throw ParseError.unknownFlag(token)
            }
            if option.takesValue {
                if let inline {
                    values[name] = inline
                } else if index < argv.count {
                    values[name] = argv[index]
                    index += 1
                } else {
                    throw ParseError.missingValue(name)
                }
            } else {
                guard inline == nil else { throw ParseError.unexpectedValue(name) }
                flags.insert(name)
            }
        }
        return Arguments(positionals: positionals, values: values, flags: flags)
    }

    public func flag(_ name: String) -> Bool { flags.contains(name) }
    public func option(_ name: String) -> String? { values[name] }
}
