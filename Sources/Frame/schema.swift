/// A type that tells editors what its Frame values may hold.
public protocol FrameDescribable {
    static var frameSchema: Frame.Schema { get }
}

/// A String-backed enum describes itself by its cases.
public extension FrameDescribable where Self: CaseIterable & RawRepresentable, RawValue == String {
    static var frameSchema: Frame.Schema { .members(of: Self.self) }
}

public extension Frame {
    /// What a value of a type may hold: completion offers its fields and
    /// members, hover shows its summaries. The decoder still decides what is
    /// valid; a schema only describes it.
    struct Schema: Sendable, Equatable {
        public indirect enum Shape: Sendable, Equatable {
            case string, integer, decimal, boolean
            /// `.name` values, e.g. the cases of a String-backed enum.
            case members([Member])
            /// `.{ .name = value }` values.
            case object([Property])
            case array(Schema)
            /// Anything; nothing to offer.
            case any
        }

        public struct Member: Sendable, Equatable {
            public let name: String
            public let summary: String?

            public init(_ name: String, summary: String? = nil) {
                self.name = name
                self.summary = summary
            }
        }

        public struct Property: Sendable, Equatable {
            public let name: String
            public let schema: Schema
            /// An optional property may be left out and keeps its default.
            public let required: Bool
            public let summary: String?

            public init(_ name: String, _ schema: Schema, required: Bool = false, summary: String? = nil) {
                self.name = name
                self.schema = schema
                self.required = required
                self.summary = summary
            }
        }

        public let shape: Shape
        public let summary: String?

        public init(_ shape: Shape, summary: String? = nil) {
            self.shape = shape
            self.summary = summary
        }

        public static let string = Schema(.string)
        public static let integer = Schema(.integer)
        public static let decimal = Schema(.decimal)
        public static let boolean = Schema(.boolean)
        public static let any = Schema(.any)

        public static func object(_ properties: [Property], summary: String? = nil) -> Schema {
            .init(.object(properties), summary: summary)
        }

        public static func array(_ element: Schema, summary: String? = nil) -> Schema {
            .init(.array(element), summary: summary)
        }

        public static func of<T: FrameDescribable>(_ type: T.Type) -> Schema {
            type.frameSchema
        }

        /// Every case of a String-backed enum, as members.
        public static func members<T: CaseIterable & RawRepresentable>(
            of type: T.Type,
            summary: String? = nil
        ) -> Schema where T.RawValue == String {
            .init(.members(type.allCases.map { Member($0.rawValue) }), summary: summary)
        }

        /// Every case, with a summary for those that have one.
        public static func members<T: CaseIterable & RawRepresentable & Hashable>(
            of type: T.Type,
            summary: String? = nil,
            summaries: [T: String]
        ) -> Schema where T.RawValue == String {
            .init(.members(type.allCases.map { Member($0.rawValue, summary: summaries[$0]) }), summary: summary)
        }

        public var properties: [Property] {
            guard case .object(let properties) = shape else { return [] }
            return properties
        }

        public var members: [Member] {
            guard case .members(let members) = shape else { return [] }
            return members
        }

        /// The schema at a field path, e.g. `["paths", "ask"]`. Arrays are
        /// transparent: a path into an array names fields of its elements.
        public func schema(at path: [String]) -> Schema? {
            guard let name = path.first else { return self }
            switch shape {
            case .array(let element):
                return element.schema(at: path)
            case .object(let properties):
                return properties.first { $0.name == name }?.schema.schema(at: Array(path.dropFirst()))
            default:
                return nil
            }
        }
    }
}
