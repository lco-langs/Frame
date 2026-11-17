import Foundation
import Position

public extension Frame.Schema {
    /// Everything about `value` this schema rejects, not only the first:
    /// unknown and missing fields, wrong kinds and unknown members. Each
    /// problem points at the nearest field, or at `range` above them.
    func problems(
        in value: Frame.Value,
        named root: String,
        range: PositionRange,
        document: Frame.Document
    ) -> [Frame.TypeFailure] {
        var problems: [Frame.TypeFailure] = []
        FrameSchemaChecker(document: document).check(value, against: self, path: root, range: range, into: &problems)
        return problems
    }
}

public extension FrameDescribable where Self: Encodable {
    /// What this type's schema rejects in `value`, encoded: a test that the
    /// schema kept up with the type's fields, kinds and cases.
    static func frameSchemaProblems(in value: Self) throws -> [Frame.TypeFailure] {
        frameSchema.problems(in: try FrameEncoder().encode(value), named: "\(Self.self)",
                             range: .point(0), document: Frame.Document(bindings: []))
    }
}

public extension Frame.TypeDefinition {
    /// A type known only by its schema, as read from a module file.
    static func described(_ schema: Frame.Schema, named name: String) -> Self {
        .init(name: name, schema: schema) { value, document, _ in
            if let problem = schema.problems(in: value, named: name, range: .point(0), document: document).first {
                throw problem
            }
        }
    }
}

public extension Frame.Module {
    /// The types of a module file: its `Type` bindings.
    init(_ name: String, loading document: Frame.Document) throws {
        self.init(name, types: try Frame.Schema.types(in: document).map { .described($0.schema, named: $0.name) })
    }
}

public extension Frame {
    /// Where module files live for editors: `$XDG_CONFIG_HOME/frame/modules`,
    /// by default `~/.config/frame/modules`.
    static var modulesDirectory: URL {
        let configuration = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : $0 }
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).appendingPathComponent(".config", isDirectory: true)
        return configuration.appendingPathComponent("frame/modules", isDirectory: true)
    }
}

public extension Frame.Module {
    /// Writes `<name>.frame` into `directory`, replacing an older one.
    @discardableResult
    func install(into directory: URL = Frame.modulesDirectory) throws -> URL {
        let file = directory.appendingPathComponent("\(name).frame")
        let header = "// Written by the program that defines '\(name)'; regenerate rather than edit.\n"
        try FrameFiles.write(header + document().source, to: file)
        return file
    }
}

public extension Frame.Environment {
    struct Loaded: Sendable {
        public let environment: Frame.Environment
        /// Module files that could not be read; the others still load.
        public let failures: [(file: URL, error: any Error)]
    }

    /// `Frame` and every `<Module>.frame` in `directory`; a missing
    /// directory has no modules.
    static func loading(modulesIn directory: URL, coding: FrameCoding = .init()) -> Loaded {
        var modules: [Frame.Module] = [.frame]
        var failures: [(file: URL, error: any Error)] = []
        let files: [URL]
        do {
            files = try FrameFiles.files(in: directory, pathExtension: "frame")
        } catch {
            return Loaded(environment: .init(modules, coding: coding), failures: [(directory, error)])
        }
        for file in files {
            do {
                let source = try FrameFiles.read(file)
                let document = try Frame.parse(source, filePath: file.path, environment: .init([.frame]))
                modules.append(try Frame.Module(file.deletingPathExtension().lastPathComponent, loading: document))
            } catch {
                failures.append((file, error))
            }
        }
        return Loaded(environment: .init(modules, coding: coding), failures: failures)
    }
}

private struct FrameSchemaChecker {
    let document: Frame.Document

    func check(
        _ value: Frame.Value,
        against schema: Frame.Schema,
        path: String,
        range: PositionRange,
        into problems: inout [Frame.TypeFailure]
    ) {
        func fail(_ message: String) { problems.append(.init(message: message, range: range)) }

        var value = value
        if case .reference(let reference) = value {
            do { value = try document.resolve(reference) } catch {
                return fail("'\(path)': \(reference.description) does not resolve (\(error))")
            }
        }
        switch (schema.shape, value) {
        case (.any, _),
             (.string, .string), (.string, .member),
             (.integer, .integer),
             (.decimal, .integer), (.decimal, .decimal),
             (.boolean, .boolean):
            return
        case (.members(let members), .member(let name)), (.members(let members), .string(let name)):
            guard !members.contains(where: { $0.name == name }) else { return }
            fail("'\(path)': unknown member '.\(name)'; expected \(members.map { ".\($0.name)" }.joined(separator: ", "))")
        case (.array(let element), .array(let values)):
            for (index, item) in values.enumerated() {
                check(item, against: element, path: "\(path)[\(index)]", range: range, into: &problems)
            }
        case (.object(let properties), .object(let fields)):
            for field in fields {
                guard let property = properties.first(where: { $0.name == field.name }) else {
                    problems.append(.init(message: "'\(path)': unknown field '\(field.name)'", range: field.range))
                    continue
                }
                if case .null = field.value {
                    if property.required {
                        problems.append(.init(message: "'\(path).\(field.name)' is required", range: field.range))
                    }
                    continue
                }
                check(field.value, against: property.schema, path: "\(path).\(field.name)",
                      range: field.range, into: &problems)
            }
            for property in properties where property.required && !fields.contains(where: { $0.name == property.name }) {
                fail("'\(path)': missing field '\(property.name)'")
            }
        default:
            fail("'\(path)' expects \(Self.describe(schema.shape)), found \(Self.describe(value))")
        }
    }

    static func describe(_ shape: Frame.Schema.Shape) -> String {
        switch shape {
        case .string: "a string"
        case .integer: "an integer"
        case .decimal: "a number"
        case .boolean: "a boolean"
        case .members(let members): "one of " + members.map { ".\($0.name)" }.joined(separator: ", ")
        case .object: "an object .{ … }"
        case .array: "an array [ … ]"
        case .any: "anything"
        }
    }

    static func describe(_ value: Frame.Value) -> String {
        switch value {
        case .string: "a string"
        case .integer: "an integer"
        case .decimal: "a decimal"
        case .boolean: "a boolean"
        case .null: "null"
        case .object: "an object"
        case .array: "an array"
        case .reference(let reference): "'\(reference.description)'"
        case .member(let name): "'.\(name)'"
        }
    }
}
