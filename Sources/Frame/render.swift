import Foundation

public extension Frame {
    /// Frame source for a value, as a person would write it: short values on
    /// one line, longer ones broken with trailing commas, text with line
    /// breaks as a block string.
    static func render(_ value: Value) -> String {
        FrameRenderer().value(value, depth: 0)
    }

    /// Whether `name` can be written bare as a binding, field or member name.
    static func isIdentifier(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first,
              first == "_" || first.properties.isLetterCategory,
              !keywords.contains(name) else {
            return false
        }
        return name.unicodeScalars.dropFirst().allSatisfy {
            $0 == "_" || $0 == "-" || $0.properties.isLetterCategory || $0.properties.isNumberCategory
        }
    }

    private static let keywords: Set<String> = ["import", "let", "var", "true", "false", "null"]
}

public extension Frame.Document {
    /// The imports, then every binding as a declaration. Reassignments are
    /// already folded into the bindings, so none are written.
    var source: String {
        let renderer = FrameRenderer()
        let imports = imports.map { "import \($0.module);" }
        let bindings = bindings.map { binding in
            let keyword = binding.mutability == .constant ? "let" : "var"
            let type = binding.type.map { ": \($0.description)" } ?? ""
            return "\(keyword) \(binding.name)\(type) = \(renderer.value(binding.value, depth: 0));"
        }
        return ([imports.joined(separator: "\n")].filter { !$0.isEmpty } + bindings)
            .joined(separator: "\n\n") + "\n"
    }
}

private struct FrameRenderer {
    let indentation = "    "
    let width = 80

    func value(_ value: Frame.Value, depth: Int) -> String {
        if let inline = inline(value), inline.count + depth * indentation.count <= width {
            return inline
        }
        let inner = String(repeating: indentation, count: depth + 1)
        let outer = String(repeating: indentation, count: depth)
        switch value {
        case .object(let fields):
            let lines = fields.map { "\(inner).\($0.name) = \(self.value($0.value, depth: depth + 1))," }
            return ".{\n" + lines.joined(separator: "\n") + "\n\(outer)}"
        case .array(let values):
            let lines = values.map { "\(inner)\(self.value($0, depth: depth + 1))," }
            return "[\n" + lines.joined(separator: "\n") + "\n\(outer)]"
        case .string(let text) where text.contains("\n"):
            return block(text, indent: inner)
        default:
            return inline(value) ?? ""
        }
    }

    /// `nil` when the value cannot sit on one line.
    func inline(_ value: Frame.Value) -> String? {
        switch value {
        case .string(let text):
            return text.contains("\n") ? nil : quoted(text)
        case .integer(let number):
            return String(number)
        case .decimal(let number):
            return number.description
        case .boolean(let flag):
            return flag ? "true" : "false"
        case .null:
            return "null"
        case .reference(let reference):
            return reference.description
        case .member(let name):
            return ".\(name)"
        case .object(let fields):
            guard !fields.isEmpty else { return ".{}" }
            var parts: [String] = []
            for field in fields {
                guard let rendered = inline(field.value) else { return nil }
                parts.append(".\(field.name) = \(rendered)")
            }
            return ".{ " + parts.joined(separator: ", ") + " }"
        case .array(let values):
            var parts: [String] = []
            for item in values {
                guard let rendered = inline(item) else { return nil }
                parts.append(rendered)
            }
            return "[" + parts.joined(separator: ", ") + "]"
        }
    }

    func quoted(_ text: String) -> String {
        "\"" + escaped(text, quotes: true, newlines: true) + "\""
    }

    /// The closing quotes sit on their own line at `indent`, which every
    /// line drops again when parsed.
    func block(_ text: String, indent: String) -> String {
        let body = escaped(text, quotes: text.contains("\"\"\""), newlines: false)
        let lines = body.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.isEmpty ? "" : indent + $0 }
        return "\"\"\"\n" + lines.joined(separator: "\n") + "\n\(indent)\"\"\""
    }

    func escaped(_ text: String, quotes: Bool, newlines: Bool) -> String {
        var result = ""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\\": result += "\\\\"
            case "\"" where quotes: result += "\\\""
            case "\n" where newlines: result += "\\n"
            case "\n": result += "\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            case _ where scalar.properties.generalCategory == .control:
                result += "\\u{\(String(scalar.value, radix: 16))}"
            default: result.unicodeScalars.append(scalar)
            }
        }
        return result
    }
}

private extension Unicode.Scalar.Properties {
    var isLetterCategory: Bool {
        switch generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter: true
        default: false
        }
    }

    var isNumberCategory: Bool {
        switch generalCategory {
        case .decimalNumber, .letterNumber, .otherNumber: true
        default: false
        }
    }
}
