import Errors
import Foundation
import Parsing

extension Frame.SyntaxFailure:
    SemanticError,
    ErrorDispositionProviding
{
    public var errorIdentity: ErrorIdentity {
        .init(namespace: "frame", code: "syntax")
    }

    public var errorPresentation: ErrorPresentation {
        .init(
            message: "Frame syntax error\(Frame.at(line, column)).",
            // The parser's text may quote the source.
            reason: diagnostic.message,
            reasonSensitivity: .potentially_sensitive
        )
    }

    public var errorDiagnosticFields: [ErrorDiagnosticField] {
        Frame.locationFields(line, column) + diagnostic.errorFields
    }

    public var errorDisposition: ErrorDisposition? {
        .invalid_input
    }
}

extension Frame.TypeFailure:
    SemanticError,
    ErrorDispositionProviding
{
    public var errorIdentity: ErrorIdentity {
        .init(namespace: "frame", code: "type_check")
    }

    public var errorPresentation: ErrorPresentation {
        .init(
            message: "Frame type error\(Frame.at(line, column)).",
            reason: message,
            reasonSensitivity: .potentially_sensitive
        )
    }

    public var errorDiagnosticFields: [ErrorDiagnosticField] {
        Frame.locationFields(line, column)
    }

    public var errorDisposition: ErrorDisposition? {
        .invalid_input
    }
}

extension Frame.ResolutionFailure:
    SemanticError,
    ErrorNamespaced,
    ErrorDispositionProviding
{
    public static let errorNamespace = "frame.reference"

    public var errorCode: String {
        switch self {
        case .invalid_reference: return "invalid"
        case .missing: return "missing"
        case .ambiguous: return "ambiguous"
        case .not_object: return "not_object"
        case .cycle: return "cycle"
        }
    }

    public var errorPresentation: ErrorPresentation {
        switch self {
        case .missing:
            return .init(
                message: "Frame reference error: \(description).",
                recoverySuggestion: "Declare it, or import the file that does."
            )
        default:
            return .init(message: "Frame reference error: \(description).")
        }
    }

    public var errorDiagnosticFields: [ErrorDiagnosticField] {
        switch self {
        case .invalid_reference:
            return []
        case .missing(let reference),
             .ambiguous(let reference),
             .not_object(let reference),
             .cycle(let reference):
            return [.init(key: "frame.reference", value: reference.components.joined(separator: "."))]
        }
    }

    public var errorDisposition: ErrorDisposition? {
        .invalid_input
    }
}

extension FrameFiles.Failure:
    SemanticError,
    ErrorNamespaced,
    ErrorDispositionProviding
{
    static let errorNamespace = "frame.file"

    var errorCode: String {
        switch self {
        case .not_a_file: return "not_a_file"
        case .not_utf8: return "not_utf8"
        case .incomplete_write: return "incomplete_write"
        }
    }

    var errorPresentation: ErrorPresentation {
        .init(
            message: "\(description).",
            messageSensitivity: .potentially_sensitive
        )
    }

    var errorDiagnosticFields: [ErrorDiagnosticField] {
        switch self {
        case .not_a_file(let url), .not_utf8(let url), .incomplete_write(let url):
            return [.init(key: "path", value: url.path, sensitivity: .potentially_sensitive)]
        }
    }

    var errorDisposition: ErrorDisposition? {
        switch self {
        case .not_a_file, .not_utf8:
            return .invalid_input
        case .incomplete_write:
            return nil
        }
    }
}

extension Frame {
    /// ` at 3:7`, or nothing when the location is unknown.
    fileprivate static func at(_ line: Int?, _ column: Int?) -> String {
        guard let line, let column else { return "" }
        return " at \(line):\(column)"
    }

    fileprivate static func locationFields(_ line: Int?, _ column: Int?) -> [ErrorDiagnosticField] {
        guard let line, let column else { return [] }
        return [
            .init(key: "source.line", value: line),
            .init(key: "source.column", value: column),
        ]
    }
}
