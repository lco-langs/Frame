import Foundation
import enum Grammar.Grammar
import GrammarParsing
import Parsing
import Position

public extension Frame {
    struct SyntaxFailure: Error, Sendable, CustomStringConvertible {
        public let diagnostic: Diagnostic
        public init(_ diagnostic: Diagnostic) { self.diagnostic = diagnostic }
        public var description: String { diagnostic.description }
    }

    static func tree(_ source: String, filePath: String? = nil) throws -> GrammarParser.Node {
        try native.get().parse(source, filePath: filePath)
    }

    static func parse(_ source: String, filePath: String? = nil) throws -> Document {
        let root: GrammarParser.Node
        do {
            root = try tree(source, filePath: filePath)
        } catch GrammarParser.Failure.syntax(let diagnostic) {
            throw SyntaxFailure(diagnostic)
        } catch GrammarParser.Failure.lexical(let error) {
            let range = try? Position.TextMap(source: source).legacyRange(error.range)
            throw SyntaxFailure(Diagnostic(error.message, range: range, utf8Range: error.range))
        }
        return try Adapter(source: source).document(root)
    }

    private static let native: Result<GrammarParser, any Error> = Result {
        try GrammarParser(language: language())
    }
}

private struct Adapter {
    let map: Position.TextMap
    init(source: String) { map = Position.TextMap(source: source) }

    func document(_ node: GrammarParser.Node) throws -> Frame.Document {
        var imports: [Frame.Import] = []
        var bindings: [Frame.Binding] = []
        for child in node.children {
            switch child.name {
            case "import":
                guard let module = child.children.first(where: { $0.field == "module" })?.text else {
                    throw failure("Missing module name", at: child)
                }
                guard !imports.contains(where: { $0.module == module }) else {
                    throw failure("'\(module)' is already imported", at: child)
                }
                imports.append(.init(module: module, range: try map.legacyRange(child.range)))
            case "binding":
                let binding = try self.binding(child)
                guard !bindings.contains(where: { $0.name == binding.name }) else {
                    throw failure("'\(binding.name)' is already declared", at: child)
                }
                bindings.append(binding)
            case "assignment":
                try assign(child, in: &bindings)
            default:
                continue
            }
        }
        return Frame.Document(imports: imports, bindings: bindings)
    }

    func binding(_ node: GrammarParser.Node) throws -> Frame.Binding {
        guard let mutability = node.children.first(where: { $0.field == "mutability" }).flatMap(text),
              let name = node.children.first(where: { $0.field == "name" })?.text,
              let value = node.children.first(where: { $0.field == "value" }) else {
            throw failure("Incomplete declaration", at: node)
        }
        let type = try node.children.first(where: { $0.field == "type" }).map { type in
            try Frame.Reference(components: type.children.compactMap { $0.name == "identifier" ? $0.text : nil })
        }
        return Frame.Binding(
            name: name,
            mutability: mutability == "let" ? .constant : .variable,
            type: type,
            value: try self.value(value),
            range: try map.legacyRange(node.range)
        )
    }

    /// `name = value;` replaces a `var`; `name.a.b = value;` one field in it.
    func assign(_ node: GrammarParser.Node, in bindings: inout [Frame.Binding]) throws {
        guard let target = node.children.first(where: { $0.field == "target" }),
              let value = node.children.first(where: { $0.field == "value" }) else {
            throw failure("Incomplete assignment", at: node)
        }
        let path = target.children.compactMap { $0.name == "identifier" ? $0.text : nil }
        guard let index = bindings.firstIndex(where: { $0.name == path.first }) else {
            throw failure("'\(path.first ?? "")' is not declared; declare it with var", at: node)
        }
        let binding = bindings[index]
        guard binding.mutability == .variable else {
            throw failure("'\(binding.name)' is a let constant", at: node)
        }
        let replaced = try setting(
            binding.value,
            at: Array(path.dropFirst()),
            to: try self.value(value),
            range: try map.legacyRange(node.range),
            node: node
        )
        bindings[index] = Frame.Binding(
            name: binding.name,
            mutability: binding.mutability,
            type: binding.type,
            value: replaced,
            range: binding.range
        )
    }

    func setting(
        _ value: Frame.Value,
        at path: [String],
        to new: Frame.Value,
        range: PositionRange,
        node: GrammarParser.Node
    ) throws -> Frame.Value {
        guard let name = path.first else { return new }
        guard case .object(var fields) = value else {
            throw failure("'\(name)' is not inside an object literal", at: node)
        }
        if let index = fields.firstIndex(where: { $0.name == name }) {
            fields[index] = Frame.Field(
                name: name,
                value: try setting(fields[index].value, at: Array(path.dropFirst()), to: new, range: range, node: node),
                range: range
            )
        } else {
            fields.append(Frame.Field(
                name: name,
                value: try setting(.object([]), at: Array(path.dropFirst()), to: new, range: range, node: node),
                range: range
            ))
        }
        return .object(fields)
    }

    func text(_ node: GrammarParser.Node) -> String? {
        node.text ?? node.children.first.flatMap(text)
    }

    func fields(in node: GrammarParser.Node) throws -> [Frame.Field] {
        var fields: [Frame.Field] = []
        for child in node.children {
            if child.name == "field" {
                guard let name = child.children.first(where: { $0.field == "name" })?.text,
                      let value = child.children.first(where: { $0.field == "value" }) else {
                    throw failure("Incomplete field", at: child)
                }
                guard !fields.contains(where: { $0.name == name }) else {
                    throw failure("Duplicate field '\(name)'", at: child)
                }
                fields.append(.init(name: name, value: try self.value(value), range: try map.legacyRange(child.range)))
            }
            if child.name == "fields" { fields.append(contentsOf: try self.fields(in: child)) }
        }
        return fields
    }

    func value(_ node: GrammarParser.Node) throws -> Frame.Value {
        switch node.name {
        case "value":
            guard let child = node.children.first else { throw failure("Missing Frame value", at: node) }
            return try value(child)
        case "quoted":
            guard let raw = node.text, raw.count >= 2 else { throw failure("Missing string literal", at: node) }
            return .string(try unescape(String(raw.dropFirst().dropLast()), at: node))
        case "block_quoted":
            guard let raw = node.text, raw.count >= 6 else { throw failure("Missing block string", at: node) }
            return .string(try unescape(try dedent(String(raw.dropFirst(3).dropLast(3)), at: node), at: node))
        case "number":
            guard let raw = node.text else { throw failure("Missing numeric literal", at: node) }
            if raw.contains(".") {
                guard let decimal = Decimal(string: raw, locale: Locale(identifier: "en_US_POSIX")) else {
                    throw failure("Invalid decimal literal", at: node)
                }
                return .decimal(decimal)
            }
            guard let integer = Int(raw) else { throw failure("Integer out of range", at: node) }
            return .integer(integer)
        case "boolean":
            guard let raw = node.text else { throw failure("Missing boolean literal", at: node) }
            return .boolean(raw == "true")
        case "null":
            return .null
        case "reference":
            let components = node.children.compactMap { child in
                child.name == "identifier" ? child.text : nil
            }
            return .reference(try Frame.Reference(components: components))
        case "member":
            guard let name = node.children.first(where: { $0.field == "name" })?.text else {
                throw failure("Missing member name", at: node)
            }
            return .member(name)
        case "call":
            // `.name(value)` is the one-field object `.{ .name = value }`; `.name(a, b)` makes the
            // field an array, and `.name()` is the plain member `.name`.
            guard let name = node.children.first(where: { $0.field == "name" })?.text else {
                throw failure("Missing call name", at: node)
            }
            let arguments = try node.children.first(where: { $0.name == "array_items" }).map(arrayItems) ?? []
            switch arguments.count {
            case 0: return .member(name)
            case 1: return .object([.init(name: name, value: arguments[0], range: try map.legacyRange(node.range))])
            default: return .object([.init(name: name, value: .array(arguments), range: try map.legacyRange(node.range))])
            }
        case "literal":
            return .object(try fields(in: node))
        case "array":
            guard let items = node.children.first(where: { $0.name == "array_items" }) else {
                return .array([])
            }
            return .array(try arrayItems(items))
        default:
            throw failure("Unexpected Frame node '\(node.name)'", at: node)
        }
    }

    func arrayItems(_ node: GrammarParser.Node) throws -> [Frame.Value] {
        var values: [Frame.Value] = []
        for child in node.children {
            if child.name == "value" { values.append(try value(child)) }
            if child.name == "array_items" { values.append(contentsOf: try arrayItems(child)) }
        }
        return values
    }

    /// The line after the opening `"""` starts the text; the closing `"""`
    /// on a line of its own sets the indentation every line drops.
    func dedent(_ body: String, at node: GrammarParser.Node) throws -> String {
        var lines = body.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.count > 1 else { return body }
        if lines[0].allSatisfy(\.isWhitespace) { lines.removeFirst() }
        guard let indent = lines.last, indent.allSatisfy({ $0 == " " || $0 == "\t" }) else {
            return lines.joined(separator: "\n")
        }
        lines.removeLast()
        return try lines.map { line in
            if line.hasPrefix(indent) { return String(line.dropFirst(indent.count)) }
            guard line.allSatisfy(\.isWhitespace) else {
                throw failure("A block string line is indented less than its closing \"\"\"", at: node)
            }
            return ""
        }.joined(separator: "\n")
    }

    /// The text between the quotes, with escapes replaced.
    func unescape(_ content: String, at node: GrammarParser.Node) throws -> String {
        let scalars = Array(content.unicodeScalars)
        var result = String.UnicodeScalarView()
        var index = 0
        while index < scalars.count {
            if scalars[index] != "\\" {
                result.append(scalars[index])
                index += 1
                continue
            }
            index += 1
            guard index < scalars.count else { throw failure("Incomplete string escape", at: node) }
            switch scalars[index] {
            case "n": result.append("\n")
            case "r": result.append("\r")
            case "t": result.append("\t")
            case "\"": result.append("\"")
            case "\\": result.append("\\")
            case "u":
                guard index + 1 < scalars.count, scalars[index + 1] == "{" else {
                    throw failure("Expected '{' after unicode escape", at: node)
                }
                index += 2
                var digits = ""
                while index < scalars.count && scalars[index] != "}" {
                    digits.unicodeScalars.append(scalars[index])
                    index += 1
                }
                guard index < scalars.count, digits.count <= 8,
                      let number = UInt32(digits, radix: 16),
                      let unicode = Unicode.Scalar(number) else {
                    throw failure("Invalid unicode escape", at: node)
                }
                result.append(unicode)
            default: throw failure("Unsupported string escape", at: node)
            }
            index += 1
        }
        return String(result)
    }

    func failure(_ message: String, at node: GrammarParser.Node) -> Frame.SyntaxFailure {
        Frame.SyntaxFailure(Diagnostic(message, range: try? map.legacyRange(node.range), utf8Range: node.range))
    }
}
