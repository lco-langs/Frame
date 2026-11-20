import Foundation
import Frame

/// `frame json <file>`: every binding of a Frame file as one JSON object,
/// references resolved, `.member` values as strings. For scripts that read
/// Frame configuration without a Swift type for it.
@main
enum FrameCLI {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.count == 2, arguments[0] == "json" else {
            FileHandle.standardError.write(Data("usage: frame json <file.frame>\n".utf8))
            exit(64)
        }
        let path = arguments[1]
        do {
            let source = try String(contentsOfFile: path, encoding: .utf8)
            let document = try Frame.parse(source, filePath: path)
            var object: [String: Any] = [:]
            for binding in document.bindings {
                object[binding.name] = try json(binding.value, in: document)
            }
            let data = try JSONSerialization.data(
                withJSONObject: object,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            )
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
        } catch {
            FileHandle.standardError.write(Data("\(path): \(error)\n".utf8))
            exit(65)
        }
    }

    static func json(_ value: Frame.Value, in document: Frame.Document) throws -> Any {
        switch value {
        case .string(let string): return string
        case .integer(let integer): return integer
        case .decimal(let decimal): return NSDecimalNumber(decimal: decimal)
        case .boolean(let boolean): return boolean
        case .null: return NSNull()
        case .member(let name): return name
        case .reference(let reference): return try json(document.resolve(reference), in: document)
        case .array(let values): return try values.map { try json($0, in: document) }
        case .object(let fields):
            var object: [String: Any] = [:]
            for field in fields { object[field.name] = try json(field.value, in: document) }
            return object
        }
    }
}
