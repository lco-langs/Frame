import Foundation
import Position

public extension Frame {
    /// Types a program offers to `import <name>;`. Frame itself knows no
    /// domain types; a program registers its modules before parsing.
    struct Module: Sendable {
        public let name: String
        public let types: [TypeDefinition]

        public init(_ name: String, types: [TypeDefinition]) {
            self.name = name
            self.types = types
        }
    }

    /// A nameable type: checked by decoding a value into its Swift type.
    struct TypeDefinition: Sendable {
        public let name: String
        /// For editors; `nil` when the type does not describe itself.
        public let schema: Schema?
        let check: @Sendable (Value, Document, FrameCoding) throws -> Void

        public static func decodable<T: Decodable & Sendable>(
            _ type: T.Type,
            named name: String
        ) -> Self {
            .init(name: name, schema: nil) { value, document, coding in
                _ = try coding.decode(type, value: value, in: document)
            }
        }

        public static func decodable<T: Decodable & Sendable & FrameDescribable>(
            _ type: T.Type,
            named name: String
        ) -> Self {
            .init(name: name, schema: type.frameSchema) { value, document, coding in
                _ = try coding.decode(type, value: value, in: document)
            }
        }
    }

    /// The modules a document may import.
    struct Environment: Sendable {
        public let modules: [Module]
        public let coding: FrameCoding

        public init(_ modules: [Module] = [], coding: FrameCoding = .init()) {
            self.modules = modules
            self.coding = coding
        }
    }

    /// An import, a type annotation or a value that does not hold.
    struct TypeFailure: Error, Sendable, CustomStringConvertible {
        public let message: String
        public let range: PositionRange
        /// 1-based, when the source is known.
        public var line: Int?
        public var column: Int?

        init(message: String, range: PositionRange) {
            self.message = message
            self.range = range
        }

        public var description: String {
            guard let line, let column else { return message }
            return "\(line):\(column): \(message)"
        }

        /// With the 1-based line and column of its start in `source`.
        public func located(in source: String) -> Self {
            var failure = self
            let before = source.prefix(range.start.offset)
            failure.line = before.filter { $0 == "\n" }.count + 1
            failure.column = before.count - (before.lastIndex(of: "\n").map { before.distance(from: before.startIndex, to: $0) + 1 } ?? 0) + 1
            return failure
        }
    }

    /// Parses, then checks imports against `environment` and every
    /// annotated binding against its type.
    static func parse(
        _ source: String,
        filePath: String? = nil,
        environment: Environment
    ) throws -> Document {
        let document = try parse(source, filePath: filePath)
        do {
            try check(document, in: environment)
        } catch let failure as TypeFailure {
            throw failure.located(in: source)
        }
        return document
    }

    /// The first failure, as the type's decoder sees it: a program trusts
    /// its own decoder, never a schema that may have fallen behind it.
    static func check(
        _ document: Document,
        in environment: Environment
    ) throws {
        if let failure = failures(in: document, environment: environment, bySchema: false).first {
            throw failure
        }
    }

    /// Checks `document` with `context` in scope for references, as when several
    /// files form one configuration: only `document`'s own bindings are checked.
    static func check(
        _ document: Document,
        in environment: Environment,
        context: [Binding]
    ) throws {
        let own = Set(document.bindings.map(\.name))
        let visible = context
            .filter { !own.contains($0.name) }
            .map { Binding(name: $0.name, mutability: $0.mutability, type: nil, value: $0.value, range: $0.range) }
        try check(Document(imports: document.imports, bindings: document.bindings + visible), in: environment)
    }

    /// Every failure, for editors: a type's schema reports all its problems
    /// at their fields; the decoder still has the last word on what passes.
    static func problems(
        in document: Document,
        environment: Environment
    ) -> [TypeFailure] {
        failures(in: document, environment: environment, bySchema: true)
    }

    private static func failures(
        in document: Document,
        environment: Environment,
        bySchema: Bool
    ) -> [TypeFailure] {
        var failures: [TypeFailure] = []
        var imported: [Module] = []
        for item in document.imports {
            guard let module = environment.modules.first(where: { $0.name == item.module }) else {
                failures.append(TypeFailure(message: "No module named '\(item.module)'", range: item.range))
                continue
            }
            imported.append(module)
        }
        for binding in document.bindings {
            guard let type = binding.type else { continue }
            let definition: TypeDefinition
            do {
                definition = try resolve(type, in: imported, at: binding.range)
            } catch {
                failures.append(error as? TypeFailure ?? TypeFailure(message: "\(error)", range: binding.range))
                continue
            }
            if bySchema, let schema = definition.schema {
                let problems = schema.problems(in: binding.value, named: binding.name,
                                               range: binding.range, document: document)
                failures += problems
                if !problems.isEmpty { continue }
            }
            do {
                try definition.check(binding.value, document, environment.coding)
            } catch let error as DecodingError {
                failures.append(TypeFailure(
                    message: "'\(binding.name)' is not a valid \(type.description): \(describe(error, root: binding.name))",
                    range: binding.range
                ))
            } catch let error as ResolutionFailure {
                failures.append(TypeFailure(message: "'\(binding.name)': \(error)", range: binding.range))
            } catch let error as TypeFailure {
                failures.append(TypeFailure(message: error.message, range: binding.range))
            } catch {
                failures.append(TypeFailure(message: "'\(binding.name)': \(error)", range: binding.range))
            }
        }
        return failures
    }

    private static func resolve(
        _ type: Reference,
        in modules: [Module],
        at range: PositionRange
    ) throws -> TypeDefinition {
        switch type.components.count {
        case 1:
            let matches = modules.compactMap { module in
                module.types.first { $0.name == type.components[0] }
            }
            guard let definition = matches.first else {
                throw TypeFailure(message: "No imported type named '\(type.description)'", range: range)
            }
            guard matches.count == 1 else {
                throw TypeFailure(message: "'\(type.description)' is ambiguous; qualify it with its module", range: range)
            }
            return definition
        case 2:
            guard let module = modules.first(where: { $0.name == type.components[0] }) else {
                throw TypeFailure(message: "'\(type.components[0])' is not imported", range: range)
            }
            guard let definition = module.types.first(where: { $0.name == type.components[1] }) else {
                throw TypeFailure(message: "No type '\(type.components[1])' in '\(module.name)'", range: range)
            }
            return definition
        default:
            throw TypeFailure(message: "'\(type.description)' is not a type name", range: range)
        }
    }

    private static func describe(
        _ error: DecodingError,
        root: String
    ) -> String {
        let context: DecodingError.Context
        switch error {
        case .typeMismatch(_, let value), .valueNotFound(_, let value), .dataCorrupted(let value):
            context = value
        case .keyNotFound(let key, let value):
            return "\(path(root, value.codingPath)): missing field '\(key.stringValue)'"
        @unknown default:
            return "\(error)"
        }
        return "\(path(root, context.codingPath)): \(context.debugDescription)"
    }

    private static func path(
        _ root: String,
        _ codingPath: [CodingKey]
    ) -> String {
        codingPath.reduce(root) { path, key in
            key.intValue.map { "\(path)[\($0)]" } ?? "\(path).\(key.stringValue)"
        }
    }
}

public extension Frame.Document {
    /// Bindings annotated with `type`, by its name with or without module.
    func bindings(ofType type: String) -> [Frame.Binding] {
        bindings.filter { $0.type?.components.last == type }
    }
}
