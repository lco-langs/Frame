import Foundation
import Frame
import IO

/// A directory laid out like a home: `.config/<app>/`, `.agentic/`. The
/// private root is the home directory; shared roots (a team's synced folder)
/// hold the same tree, so an app finds its files in every root the same way.
public struct Root: Sendable, Hashable {
    /// The home directory's root, always present and always first.
    public static let privateName = "private"

    /// `private`, or the binding name in `roots.frame`, such as `hondenmeesters`.
    public let name: String
    public let directory: URL
    /// Tools may write their own files here (review decisions, saved context).
    /// Hand-written configuration is never rewritten.
    public let writable: Bool

    public init(
        name: String,
        directory: URL,
        writable: Bool
    ) {
        self.name = name
        self.directory = directory.standardizedFileURL
        self.writable = writable
    }

    public var isPrivate: Bool {
        name == Self.privateName
    }

    public func url(
        _ location: RootLocation
    ) -> URL {
        location.components.reduce(directory) { $0.appendingPathComponent($1, isDirectory: true) }
    }
}

/// A place inside every root.
public struct RootLocation: Sendable, Hashable, CustomStringConvertible {
    public let components: [String]

    public init(
        _ components: [String]
    ) {
        self.components = components
    }

    /// `.config/<app>`, such as `.config/mail`.
    public static func config(
        _ app: String
    ) -> RootLocation {
        RootLocation([".config", app])
    }

    /// `.agentic`, the Agentic home.
    public static let agentic = RootLocation([".agentic"])

    /// `.agentic/context`, owner context.
    public static let agenticContext = RootLocation([".agentic", "context"])

    public var description: String {
        components.joined(separator: "/")
    }
}

/// The `Roots` Frame module: what `import Roots;` makes nameable in `roots.frame`.
///
/// ```
/// import Roots;
/// let hondenmeesters: Root = .{ .path = "~/Library/Mobile Documents/com~apple~CloudDocs/Shared Files/Hondenmeesters" };
/// ```
public enum Roots {
    public static let module = Frame.Module("Roots", types: [
        .decodable(Declaration.self, named: "Root"),
    ])

    public static let environment = Frame.Environment([module])

    public static let fileName = "roots.frame"

    /// One shared root, as written in `roots.frame`.
    public struct Declaration: Sendable, Hashable, Decodable {
        /// Absolute, `~`, or relative to the roots file's folder.
        public let path: String
        /// Tools may write their own files there. Defaults to false.
        public let writable: Bool?

        public init(
            path: String,
            writable: Bool? = nil
        ) {
            self.path = path
            self.writable = writable
        }
    }

    /// `$XDG_CONFIG_HOME/roots.frame`, else `~/.config/roots.frame`.
    public static func file(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = Roots.home
    ) -> URL {
        let base = environment["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
            ?? home.appendingPathComponent(".config", isDirectory: true)
        return base.appendingPathComponent(fileName)
    }

    public static var home: URL {
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    }

    /// The private root and every shared root `file` declares. A missing file
    /// means only the private root; a declared root that is not a directory is
    /// left out with a problem, so one unsynced folder never hides the others.
    public static func load(
        file: URL = Roots.file(),
        home: URL = Roots.home
    ) -> RootSet {
        var roots = [Root(name: Root.privateName, directory: home, writable: true)]
        var problems: [String] = []
        guard FileSystem.default.exists(file) else {
            return RootSet(file: file, roots: roots, problems: problems)
        }

        let document: Frame.Document
        do {
            let source = try FrameFiles.read(file)
            document = try Frame.parse(source, filePath: file.path)
            let failures = Frame.problems(in: document, environment: environment)
            guard failures.isEmpty else {
                problems += failures.map { "\(file.path):\($0.located(in: source).description)" }
                return RootSet(file: file, roots: roots, problems: problems)
            }
        } catch {
            problems.append("\(file.path): \(error)")
            return RootSet(file: file, roots: roots, problems: problems)
        }

        for binding in document.bindings(ofType: "Root") {
            let declaration: Declaration
            do {
                declaration = try document.decode(Declaration.self, binding: binding.name)
            } catch {
                problems.append("\(file.path): '\(binding.name)': \(error)")
                continue
            }
            guard binding.name != Root.privateName else {
                problems.append("\(file.path): '\(Root.privateName)' is the home directory's root; name this one differently.")
                continue
            }
            let directory = resolve(declaration.path, relativeTo: file.deletingLastPathComponent(), home: home)
            guard FileSystem.default.exists(directory) else {
                problems.append("\(binding.name): \(directory.path) is not there (not synced, or not shared with this account?); its files are skipped.")
                continue
            }
            if let same = roots.first(where: { $0.directory == directory }) {
                problems.append("\(binding.name): \(directory.path) is already the root '\(same.name)'.")
                continue
            }
            roots.append(Root(name: binding.name, directory: directory, writable: declaration.writable ?? false))
        }
        return RootSet(file: file, roots: roots, problems: problems)
    }

    /// `path` with `~` expanded against `home`, and relative paths against `base`.
    static func resolve(
        _ path: String,
        relativeTo base: URL,
        home: URL
    ) -> URL {
        if path == "~" {
            return home.standardizedFileURL
        }
        if path.hasPrefix("~/") {
            return home.appendingPathComponent(String(path.dropFirst(2)), isDirectory: true).standardizedFileURL
        }
        if path.hasPrefix("/") {
            return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        }
        return base.appendingPathComponent(path, isDirectory: true).standardizedFileURL
    }
}

/// The roots one machine reads, private first.
public struct RootSet: Sendable {
    /// The roots file read (it may not exist).
    public let file: URL
    public let roots: [Root]
    /// Why a declared root was left out, or why the file could not be read.
    public let problems: [String]

    public init(
        file: URL,
        roots: [Root],
        problems: [String]
    ) {
        self.file = file
        self.roots = roots
        self.problems = problems
    }

    public var privateRoot: Root {
        roots[0]
    }

    public var shared: [Root] {
        Array(roots.dropFirst())
    }

    public func root(
        named name: String
    ) -> Root? {
        roots.first { $0.name == name }
    }

    /// `location` in every root that has it, private first.
    public func existing(
        _ location: RootLocation
    ) -> [(root: Root, url: URL)] {
        roots.map { ($0, $0.url(location)) }.filter { FileSystem.default.exists($0.1) }
    }
}

/// What a synced folder may hold besides real files.
public struct RootFileIssues: Sendable, Equatable {
    /// Evicted iCloud files (`.accounts.frame.icloud`), by the name they stand for.
    public var notDownloaded: [URL] = []
    /// Sync conflict copies (`accounts 2.frame` beside `accounts.frame`).
    public var conflictCopies: [URL] = []

    public init() {}

    public var isEmpty: Bool {
        notDownloaded.isEmpty && conflictCopies.isEmpty
    }

    /// One line per issue, for a loader's problem list.
    public var descriptions: [String] {
        notDownloaded.map { "\($0.path) is not downloaded from iCloud (open it in Finder or run `brctl download '\($0.path)'`)." }
            + conflictCopies.map { "\($0.path) is a sync conflict copy; merge it into the original and delete it." }
    }

    /// Issues among the files with `pathExtension` below `directory`.
    public static func scan(
        _ directory: URL,
        pathExtension: String = "frame"
    ) -> RootFileIssues {
        var issues = RootFileIssues()
        guard FileSystem.default.exists(directory) else {
            return issues
        }
        var pending = [directory]
        while let folder = pending.popLast() {
            guard let entries = try? FileSystem.default.directory.entries(folder) else {
                continue
            }
            let names = Set(entries.map(\.url.lastPathComponent))
            for entry in entries {
                let name = entry.url.lastPathComponent
                if entry.kind == .directory {
                    if !name.hasPrefix(".") {
                        pending.append(entry.url)
                    }
                    continue
                }
                // `.name.frame.icloud` stands for `name.frame`.
                if name.hasPrefix("."), name.hasSuffix(".\(pathExtension).icloud") {
                    let original = String(name.dropFirst().dropLast(".icloud".count))
                    issues.notDownloaded.append(folder.appendingPathComponent(original))
                    continue
                }
                guard entry.url.pathExtension == pathExtension else {
                    continue
                }
                // `accounts 2.frame` beside `accounts.frame`.
                let stem = entry.url.deletingPathExtension().lastPathComponent
                let parts = stem.split(separator: " ")
                if parts.count >= 2, let last = parts.last, Int(last) != nil {
                    let original = parts.dropLast().joined(separator: " ") + ".\(pathExtension)"
                    if names.contains(original) {
                        issues.conflictCopies.append(entry.url)
                    }
                }
            }
        }
        issues.notDownloaded.sort { $0.path < $1.path }
        issues.conflictCopies.sort { $0.path < $1.path }
        return issues
    }
}

extension Roots.Declaration: FrameDescribable {
    public static var frameSchema: Frame.Schema {
        .object([
            .init("path", .string, required: true,
                  summary: "The shared directory, laid out like a home (.config/<app>/, .agentic/): absolute, ~, or relative to roots.frame."),
            .init("writable", .boolean,
                  summary: "Tools may write their own files there, such as review decisions. Defaults to false."),
        ], summary: "A shared root: a synced folder holding the same tree as your home, read after your own.")
    }
}
