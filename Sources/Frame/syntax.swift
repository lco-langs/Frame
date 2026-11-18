import Foundation
import Position

public extension Frame {
    struct Reference: Hashable, Sendable, Codable {
        public let components: [String]

        public init(components: [String]) throws {
            guard !components.isEmpty, components.allSatisfy({ !$0.isEmpty }) else {
                throw ResolutionFailure.invalid_reference
            }
            self.components = components
        }

        public var description: String { components.joined(separator: ".") }

        public init(from decoder: Decoder) throws {
            let parts = try decoder.singleValueContainer().decode([String].self)
            try self.init(components: parts)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(components)
        }
    }

    /// `.name = value` inside `.{ }`.
    struct Field: Sendable, Equatable {
        public let name: String
        public let value: Value
        public let range: PositionRange

        public init(name: String, value: Value, range: PositionRange) {
            self.name = name
            self.value = value
            self.range = range
        }
    }

    indirect enum Value: Sendable, Equatable {
        case string(String)
        case integer(Int)
        case decimal(Decimal)
        case boolean(Bool)
        case null
        case object([Field])
        case array([Value])
        case reference(Reference)
        /// `.name`: a member of the expected type, e.g. an enum case.
        case member(String)
    }

    struct Import: Sendable, Equatable {
        public let module: String
        public let range: PositionRange
    }

    struct Binding: Sendable, Equatable {
        public enum Mutability: Sendable, Equatable { case constant, variable }

        public let name: String
        public let mutability: Mutability
        /// As written, e.g. `PathScope` or `agentic.PathScope`.
        public let type: Reference?
        /// After every reassignment of a `var`.
        public let value: Value
        public let range: PositionRange
    }

    struct Document: Sendable, Equatable {
        public let imports: [Import]
        public let bindings: [Binding]

        public init(imports: [Import] = [], bindings: [Binding]) {
            self.imports = imports
            self.bindings = bindings
        }

        public func binding(named name: String) -> Binding? {
            bindings.first { $0.name == name }
        }

        /// Resolve a qualified accessor without coercing it into a string.
        public func resolve(_ reference: Reference) throws -> Value {
            var visited: Set<Reference> = []
            return try resolve(reference, visited: &visited)
        }

        private func resolve(_ reference: Reference, visited: inout Set<Reference>) throws -> Value {
            guard visited.insert(reference).inserted else { throw ResolutionFailure.cycle(reference) }
            defer { _ = visited.remove(reference) }
            guard let binding = binding(named: reference.components[0]) else {
                throw ResolutionFailure.missing(reference)
            }
            var resolved = binding.value
            for component in reference.components.dropFirst() {
                if case .reference(let nested) = resolved {
                    resolved = try resolve(nested, visited: &visited)
                }
                guard case .object(let fields) = resolved else {
                    throw ResolutionFailure.not_object(reference)
                }
                let matches = fields.filter { $0.name == component }
                guard let field = matches.first else { throw ResolutionFailure.missing(reference) }
                guard matches.count == 1 else { throw ResolutionFailure.ambiguous(reference) }
                resolved = field.value
            }
            if case .reference(let nested) = resolved {
                resolved = try resolve(nested, visited: &visited)
            }
            return resolved
        }
    }

    enum ResolutionFailure: Error, Sendable, Equatable {
        case invalid_reference
        case missing(Reference)
        case ambiguous(Reference)
        case not_object(Reference)
        case cycle(Reference)
    }
}

extension Frame.ResolutionFailure: CustomStringConvertible {
    public var description: String {
        func name(_ reference: Frame.Reference) -> String {
            reference.components.joined(separator: ".")
        }
        switch self {
        case .invalid_reference:
            return "invalid reference"
        case .missing(let reference):
            return "nothing named '\(name(reference))' is declared"
        case .ambiguous(let reference):
            return "'\(name(reference))' is ambiguous"
        case .not_object(let reference):
            return "'\(name(reference))' is not an object, so it has no fields"
        case .cycle(let reference):
            return "'\(name(reference))' refers to itself"
        }
    }
}
