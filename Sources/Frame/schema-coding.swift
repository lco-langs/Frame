/// A module file describes its types in Frame itself:
///
///     import Frame;
///     let Show: Type = .{ .members = [.full, .relativeToBase] };
///     let Include: Type = .{
///         .properties = [
///             .{ .name = "from", .type = .string, .required = true },
///             .{ .name = "show", .type = Show },
///             .{ .name = "paths", .type = .{ .array = .string } },
///         ],
///     };
public extension Frame.Module {
    /// What `import Frame;` makes nameable: `Type`, for module files.
    static let frame = Frame.Module("Frame", types: [.decodable(Frame.Schema.self, named: "Type")])

    /// The described types as a module file. A type that appears inside
    /// another is written by its name.
    func document(using encoder: FrameEncoder = .init()) throws -> Frame.Document {
        let encoded = try types.compactMap { type in
            try type.schema.map { (name: type.name, value: try encoder.encode($0)) }
        }
        func named(_ value: Frame.Value, root: String) throws -> Frame.Value {
            if case .object = value, let type = encoded.first(where: { $0.value == value && $0.name != root }) {
                return .reference(try Frame.Reference(components: [type.name]))
            }
            switch value {
            case .object(let fields):
                return .object(try fields.map { .init(name: $0.name, value: try named($0.value, root: root), range: $0.range) })
            case .array(let values):
                return .array(try values.map { try named($0, root: root) })
            default:
                return value
            }
        }
        return Frame.Document(
            imports: [.init(module: Self.frame.name, range: .point(0))],
            bindings: try encoded.map { type in
                Frame.Binding(name: type.name, mutability: .constant,
                              type: try Frame.Reference(components: ["Type"]),
                              value: try named(type.value, root: type.name), range: .point(0))
            }
        )
    }
}

public extension Frame.Schema {
    /// Every `Type` binding of a module file, in order.
    static func types(
        in document: Frame.Document,
        using coding: FrameCoding = .init()
    ) throws -> [(name: String, schema: Frame.Schema)] {
        try document.bindings(ofType: "Type").map { binding in
            (binding.name, try coding.decode(Frame.Schema.self, value: binding.value, in: document))
        }
    }
}

extension Frame.Schema: Codable {
    private enum Key: String, CodingKey { case summary, scalar, members, properties, array }

    private enum Scalar: String, Codable, CaseIterable {
        case string, integer, decimal, boolean, any

        var shape: Shape {
            switch self {
            case .string: .string
            case .integer: .integer
            case .decimal: .decimal
            case .boolean: .boolean
            case .any: .any
            }
        }

        init?(_ shape: Shape) {
            switch shape {
            case .string: self = .string
            case .integer: self = .integer
            case .decimal: self = .decimal
            case .boolean: self = .boolean
            case .any: self = .any
            case .members, .object, .array: return nil
            }
        }

        static func named(_ name: String, at codingPath: [CodingKey]) throws -> Self {
            guard let scalar = Self(rawValue: name) else {
                let expected = allCases.map { ".\($0.rawValue)" }.joined(separator: ", ")
                throw DecodingError.dataCorrupted(.init(codingPath: codingPath,
                    debugDescription: "Unknown type '\(name)'; expected \(expected), a type's name or .{ … }"))
            }
            return scalar
        }
    }

    /// `.string`, a type's name, or `.{ .summary, and one of .scalar,
    /// .members, .properties or .array }`.
    public init(from decoder: Decoder) throws {
        if let name = try? decoder.singleValueContainer().decode(String.self) {
            self.init(try Scalar.named(name, at: decoder.codingPath).shape)
            return
        }
        let container = try decoder.container(keyedBy: Key.self)
        let shapes = [Key.scalar, .members, .properties, .array].filter(container.contains)
        guard shapes.count <= 1 else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                debugDescription: "A type has one of .scalar, .members, .properties or .array"))
        }
        let shape: Shape
        switch shapes.first {
        case .scalar:
            shape = try Scalar.named(container.decode(String.self, forKey: .scalar),
                                     at: decoder.codingPath + [Key.scalar]).shape
        case .members:
            shape = .members(try container.decode([Member].self, forKey: .members))
        case .array:
            shape = .array(try container.decode(Frame.Schema.self, forKey: .array))
        default:
            shape = .object(try container.decodeIfPresent([Property].self, forKey: .properties) ?? [])
        }
        self.init(shape, summary: try container.decodeIfPresent(String.self, forKey: .summary))
    }

    public func encode(to encoder: Encoder) throws {
        if summary == nil, let scalar = Scalar(shape) {
            var container = encoder.singleValueContainer()
            try container.encode(Frame.Name(scalar.rawValue))
            return
        }
        var container = encoder.container(keyedBy: Key.self)
        try container.encodeIfPresent(summary, forKey: .summary)
        switch shape {
        case .members(let members): try container.encode(members, forKey: .members)
        case .object(let properties): try container.encode(properties, forKey: .properties)
        case .array(let element): try container.encode(element, forKey: .array)
        default: try container.encode(Frame.Name(Scalar(shape)?.rawValue ?? "any"), forKey: .scalar)
        }
    }
}

extension Frame.Schema.Member: Codable {
    private enum Key: String, CodingKey { case name, summary }

    /// `.name`, or `.{ .name = "name", .summary = "…" }`.
    public init(from decoder: Decoder) throws {
        if let name = try? decoder.singleValueContainer().decode(String.self) {
            self.init(name)
            return
        }
        let container = try decoder.container(keyedBy: Key.self)
        self.init(try container.decode(String.self, forKey: .name),
                  summary: try container.decodeIfPresent(String.self, forKey: .summary))
    }

    public func encode(to encoder: Encoder) throws {
        guard let summary else {
            var container = encoder.singleValueContainer()
            try container.encode(Frame.Name(name))
            return
        }
        var container = encoder.container(keyedBy: Key.self)
        try container.encode(name, forKey: .name)
        try container.encode(summary, forKey: .summary)
    }
}

extension Frame.Schema.Property: Codable {
    private enum Key: String, CodingKey { case name, type, required, summary }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Key.self)
        self.init(try container.decode(String.self, forKey: .name),
                  try container.decode(Frame.Schema.self, forKey: .type),
                  required: try container.decodeIfPresent(Bool.self, forKey: .required) ?? false,
                  summary: try container.decodeIfPresent(String.self, forKey: .summary))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Key.self)
        try container.encode(name, forKey: .name)
        try container.encode(schema, forKey: .type)
        if required { try container.encode(true, forKey: .required) }
        try container.encodeIfPresent(summary, forKey: .summary)
    }
}

/// The schema of a module file, so module files get completion too. A type
/// inside a type is `.any`: a schema cannot contain itself.
extension Frame.Schema: FrameDescribable {
    public static var frameSchema: Frame.Schema {
        let type = Frame.Schema(.any, summary: "A type: .string, .integer, .decimal, .boolean, .any, a type's name, or .{ … }.")
        return .object([
            .init("summary", .string, summary: "Shown on hover."),
            .init("scalar", .init(.members(Scalar.allCases.map { Member($0.rawValue) })),
                  summary: "A scalar type with a summary."),
            .init("members", .array(.any), summary: "The .name values it allows: .name or .{ .name, .summary }."),
            .init("properties", .array(.object([
                .init("name", .string, required: true),
                .init("type", type, required: true),
                .init("required", .boolean, summary: "Whether it must be written; false by default."),
                .init("summary", .string, summary: "Shown on hover."),
            ])), summary: "The .{ .name = value } fields it allows."),
            .init("array", type, summary: "An array of this element type."),
        ], summary: "A type a module offers to import.")
    }
}
