import Foundation
import IO

/// Module files on disk, through IO.
package enum FrameFiles {
    enum Failure: Error, Sendable, CustomStringConvertible {
        case not_a_file(URL)
        case not_utf8(URL)
        case incomplete_write(URL)

        var description: String {
            switch self {
            case .not_a_file(let url): "\(url.path) is not a regular file"
            case .not_utf8(let url): "\(url.path) is not UTF-8"
            case .incomplete_write(let url): "\(url.path) was not completely written"
            }
        }
    }

    /// The regular files in `directory` with `pathExtension`, by name; none
    /// when the directory does not exist.
    static func files(in directory: URL, pathExtension: String) throws -> [URL] {
        guard FileSystem.default.exists(directory) else { return [] }
        return try FileSystem.default.directory.entries(directory)
            .filter { $0.kind == .file && $0.url.pathExtension == pathExtension }
            .map(\.url)
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    package static func read(_ url: URL) throws -> String {
        let backend = try SystemFileSource(path: url.path, openNonblocking: true)
        guard try backend.inspect(url: url).kind == .file else { throw Failure.not_a_file(url) }
        var source = Source(backend)
        var data = Data()
        while true {
            switch try source.prepare() {
            case .bytes:
                let count = source.bufferedByteCount
                source.withReadableRegions { first, second in
                    first.withUnsafeBytes { data.append(contentsOf: $0) }
                    second.withUnsafeBytes { data.append(contentsOf: $0) }
                }
                try source.consume(count)
            case .end:
                guard let text = String(data: data, encoding: .utf8) else { throw Failure.not_utf8(url) }
                return text
            default:
                throw Failure.not_a_file(url)
            }
        }
    }

    /// Written beside `url` first, then moved over it, so a reader never sees
    /// half a file.
    package static func write(_ text: String, to url: URL) throws {
        let fileSystem = FileSystem.default
        try fileSystem.directory.create(url.deletingLastPathComponent())
        let staging = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp", isDirectory: false)
        do {
            var destination = Destination(try SystemFileDestination(path: staging.path, mode: .create))
            let bytes = Array(text.utf8)
            guard try destination.write(bytes) == .complete, try destination.flush() == .complete else {
                throw Failure.incomplete_write(url)
            }
            try destination.close()
            if fileSystem.exists(url) {
                try fileSystem.replace(url, with: staging, followingSymlinks: true)
            } else {
                try fileSystem.move(staging, to: url)
            }
        } catch {
            try? fileSystem.remove(staging)
            throw error
        }
    }
}
