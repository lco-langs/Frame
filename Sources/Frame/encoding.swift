import Foundation
import Position

/// Encodes Swift values as Frame values; `Frame.render` writes them as source.
///
/// A String-backed enum becomes a member (`.review`), so what the decoder
/// reads as a member is written as one. Dictionary keys are sorted, so the
/// same value always renders the same.
public struct FrameEncoder: Sendable {
    public init() {}

    public func encode<T: Encodable>(_ value: T) throws -> Frame.Value {
        let node = FrameEncodingNode()
        try FrameEncodingWriter(node: node, codingPath: []).box(value)
        return try node.finish(codingPath: [])
    }
}

public extension Frame {
    /// Written as a member, `.name`, by `FrameEncoder`; as a string by any
    /// other encoder. A name that is not an identifier stays a string.
    struct Name: Encodable, Sendable {
        public let name: String
        public init(_ name: String) { self.name = name }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(name)
        }
    }

    /// One `let name: type = value;` per entry, after `imports`.
    static func document<T: Encodable>(
        imports: [String] = [],
        bindings: [(name: String, type: String?, value: T)],
        using encoder: FrameEncoder = .init()
    ) throws -> Document {
        Document(
            imports: imports.map { Import(module: $0, range: .point(0)) },
            bindings: try bindings.map { binding in
                Binding(
                    name: binding.name,
                    mutability: .constant,
                    type: try binding.type.map { try Reference(components: $0.split(separator: ".").map(String.init)) },
                    value: try encoder.encode(binding.value),
                    range: .point(0)
                )
            }
        )
    }
}

/// Built while encoding; a container may still grow after its parent took it.
private final class FrameEncodingNode {
    enum Content {
        case unset
        case value(Frame.Value)
        case object([(name: String, node: FrameEncodingNode)], sorted: Bool)
        case array([FrameEncodingNode])
    }

    var content: Content = .unset

    func finish(codingPath: [CodingKey]) throws -> Frame.Value {
        switch content {
        case .unset:
            return .object([])
        case .value(let value):
            return value
        case .object(let entries, let sorted):
            let ordered = sorted ? entries.sorted { $0.name < $1.name } : entries
            return .object(try ordered.map { entry in
                let path = codingPath + [FrameEncodingKey(entry.name)]
                guard Frame.isIdentifier(entry.name) else {
                    throw EncodingError.invalidValue(entry.name, .init(codingPath: path,
                        debugDescription: "'\(entry.name)' is not a Frame field name"))
                }
                return Frame.Field(name: entry.name, value: try entry.node.finish(codingPath: path), range: .point(0))
            })
        case .array(let nodes):
            return .array(try nodes.enumerated().map { index, node in
                try node.finish(codingPath: codingPath + [FrameEncodingKey(index)])
            })
        }
    }

    func child(named name: String) -> FrameEncodingNode {
        if case .unset = content { content = .object([], sorted: false) }
        guard case .object(var entries, let sorted) = content else { return FrameEncodingNode() }
        if let existing = entries.first(where: { $0.name == name }) { return existing.node }
        let node = FrameEncodingNode()
        entries.append((name, node))
        content = .object(entries, sorted: sorted)
        return node
    }

    func appended() -> FrameEncodingNode {
        if case .unset = content { content = .array([]) }
        guard case .array(var nodes) = content else { return FrameEncodingNode() }
        let node = FrameEncodingNode()
        nodes.append(node)
        content = .array(nodes)
        return node
    }
}

/// Dictionaries encode through a keyed container; their order is not the source's.
private protocol FrameStringKeyed {}
extension Dictionary: FrameStringKeyed where Key == String {}

private struct FrameEncodingWriter: Encoder {
    let node: FrameEncodingNode
    let codingPath: [CodingKey]
    var userInfo: [CodingUserInfoKey: Any] { [:] }

    func box<T: Encodable>(_ value: T) throws {
        switch value {
        case let value as Frame.Reference:
            node.content = .value(.reference(value))
        case let value as Decimal:
            node.content = .value(.decimal(value))
        case let value as Frame.Name where Frame.isIdentifier(value.name):
            node.content = .value(.member(value.name))
        case let representable as any RawRepresentable where Mirror(reflecting: value).displayStyle == .enum:
            if let raw = representable.rawValue as? String, Frame.isIdentifier(raw) {
                node.content = .value(.member(raw))
            } else {
                try value.encode(to: self)
            }
        default:
            try value.encode(to: self)
            if value is FrameStringKeyed, case .object(let entries, _) = node.content {
                node.content = .object(entries, sorted: true)
            }
        }
    }

    func child(_ node: FrameEncodingNode, key: CodingKey) -> Self {
        .init(node: node, codingPath: codingPath + [key])
    }

    func container<Key: CodingKey>(keyedBy type: Key.Type) -> KeyedEncodingContainer<Key> {
        if case .unset = node.content { node.content = .object([], sorted: false) }
        return KeyedEncodingContainer(FrameKeyedEncoding<Key>(writer: self))
    }

    func unkeyedContainer() -> UnkeyedEncodingContainer {
        if case .unset = node.content { node.content = .array([]) }
        return FrameUnkeyedEncoding(writer: self)
    }

    func singleValueContainer() -> SingleValueEncodingContainer { FrameSingleEncoding(writer: self) }
}

private struct FrameEncodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?
    init(_ string: String) { stringValue = string; intValue = nil }
    init(_ index: Int) { stringValue = String(index); intValue = index }
    init?(stringValue: String) { self.init(stringValue) }
    init?(intValue: Int) { self.init(intValue) }
}

private struct FrameKeyedEncoding<Key: CodingKey>: KeyedEncodingContainerProtocol {
    let writer: FrameEncodingWriter
    var codingPath: [CodingKey] { writer.codingPath }

    private func slot(_ key: Key) -> FrameEncodingWriter {
        writer.child(writer.node.child(named: key.stringValue), key: key)
    }

    mutating func encodeNil(forKey key: Key) throws { slot(key).node.content = .value(.null) }
    mutating func encode<T: Encodable>(_ value: T, forKey key: Key) throws { try slot(key).box(value) }
    mutating func nestedContainer<NestedKey: CodingKey>(keyedBy keyType: NestedKey.Type,
                                                        forKey key: Key) -> KeyedEncodingContainer<NestedKey> {
        slot(key).container(keyedBy: keyType)
    }
    mutating func nestedUnkeyedContainer(forKey key: Key) -> UnkeyedEncodingContainer { slot(key).unkeyedContainer() }
    mutating func superEncoder() -> Encoder {
        let key = FrameEncodingKey("super")
        return writer.child(writer.node.child(named: key.stringValue), key: key)
    }
    mutating func superEncoder(forKey key: Key) -> Encoder { slot(key) }
}

private struct FrameUnkeyedEncoding: UnkeyedEncodingContainer {
    let writer: FrameEncodingWriter
    var count = 0
    var codingPath: [CodingKey] { writer.codingPath }

    private mutating func slot() -> FrameEncodingWriter {
        defer { count += 1 }
        return writer.child(writer.node.appended(), key: FrameEncodingKey(count))
    }

    mutating func encodeNil() throws { slot().node.content = .value(.null) }
    mutating func encode<T: Encodable>(_ value: T) throws { try slot().box(value) }
    mutating func nestedContainer<NestedKey: CodingKey>(keyedBy keyType: NestedKey.Type) -> KeyedEncodingContainer<NestedKey> {
        slot().container(keyedBy: keyType)
    }
    mutating func nestedUnkeyedContainer() -> UnkeyedEncodingContainer { slot().unkeyedContainer() }
    mutating func superEncoder() -> Encoder { slot() }
}

private struct FrameSingleEncoding: SingleValueEncodingContainer {
    let writer: FrameEncodingWriter
    var codingPath: [CodingKey] { writer.codingPath }

    private func set(_ value: Frame.Value) { writer.node.content = .value(value) }

    private func integer<T: BinaryInteger>(_ value: T) throws {
        guard let exact = Int(exactly: value) else {
            throw EncodingError.invalidValue(value, .init(codingPath: codingPath,
                debugDescription: "\(value) does not fit a Frame integer"))
        }
        set(.integer(exact))
    }

    mutating func encodeNil() throws { set(.null) }
    mutating func encode(_ value: Bool) throws { set(.boolean(value)) }
    mutating func encode(_ value: String) throws { set(.string(value)) }
    mutating func encode(_ value: Double) throws {
        guard value.isFinite, let decimal = Decimal(string: "\(value)", locale: Locale(identifier: "en_US_POSIX")) else {
            throw EncodingError.invalidValue(value, .init(codingPath: codingPath,
                debugDescription: "\(value) is not a Frame number"))
        }
        set(.decimal(decimal))
    }
    mutating func encode(_ value: Float) throws { try encode(Double(value)) }
    mutating func encode(_ value: Int) throws { set(.integer(value)) }
    mutating func encode(_ value: Int8) throws { try integer(value) }
    mutating func encode(_ value: Int16) throws { try integer(value) }
    mutating func encode(_ value: Int32) throws { try integer(value) }
    mutating func encode(_ value: Int64) throws { try integer(value) }
    mutating func encode(_ value: UInt) throws { try integer(value) }
    mutating func encode(_ value: UInt8) throws { try integer(value) }
    mutating func encode(_ value: UInt16) throws { try integer(value) }
    mutating func encode(_ value: UInt32) throws { try integer(value) }
    mutating func encode(_ value: UInt64) throws { try integer(value) }
    mutating func encode<T: Encodable>(_ value: T) throws { try writer.box(value) }
}
