import Foundation
import Frame
import IO
import Roots
import Testing

@main
enum RootsTestCLI {
    static func main() async {
        let output = ClosureTestTextOutput { text in
            FileHandle.standardOutput.write(Data(text.utf8))
        }
        let reporter = PlainTextTestReporter(verbose: CommandLine.arguments.contains("--verbose"),
                                             output: output)
        let result = await TestRunner.run(RootsTestSuite.suite, sink: reporter)
        Foundation.exit(result.isFailure ? 1 : 0)
    }
}

enum RootsTestSuite {
    static let suite = TestSuite("roots", title: "Roots") {
        Test("no-file-means-private-only") {
            try RootsTests.withoutFile()
        }
        Test("shared-roots-declared") {
            try RootsTests.declared()
        }
        Test("unreadable-file-keeps-private") {
            try RootsTests.invalid()
        }
        Test("synced-folder-issues") {
            try RootsTests.issues()
        }
    }
}

enum RootsTests {
    /// A fresh directory with `home/` and `team/` inside.
    static func scratch() throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("roots-tests-\(UUID().uuidString)", isDirectory: true)
        try FileSystem.default.directory.create(directory.appendingPathComponent("home/.config", isDirectory: true))
        try FileSystem.default.directory.create(directory.appendingPathComponent("team/.config/mail", isDirectory: true))
        return directory
    }

    static func withoutFile() throws {
        let directory = try scratch()
        let home = directory.appendingPathComponent("home", isDirectory: true)
        let set = Roots.load(file: Roots.file(environment: [:], home: home), home: home)
        try Expect.equal(set.roots.map(\.name), ["private"], "Only the home root")
        try Expect.true(set.problems.isEmpty, "A missing file is not a problem")
        try Expect.equal(set.privateRoot.url(.config("mail")).path, home.appendingPathComponent(".config/mail").path, "Mail directory")
        try Expect.equal(Roots.file(environment: ["XDG_CONFIG_HOME": "/x"], home: home).path, "/x/roots.frame", "XDG_CONFIG_HOME")
    }

    static func declared() throws {
        let directory = try scratch()
        let home = directory.appendingPathComponent("home", isDirectory: true)
        let file = home.appendingPathComponent(".config/roots.frame")
        try FrameFiles.write(
            """
            import Roots;
            let team: Root = .{ .path = "../../team", .writable = true };
            let elsewhere: Root = .{ .path = "~/not-synced" };
            let private: Root = .{ .path = "~" };
            let again: Root = .{ .path = "\(directory.appendingPathComponent("team").path)" };
            """,
            to: file
        )
        let set = Roots.load(file: file, home: home)
        try Expect.equal(set.roots.map(\.name), ["private", "team"], "Private first, then shared")
        try Expect.true(set.root(named: "team")?.writable ?? false, "Writable")
        try Expect.equal(set.problems.count, 3, "Missing, reserved name, duplicate")
        try Expect.true(set.problems.contains { $0.hasPrefix("elsewhere:") && $0.contains("not there") }, "Unsynced root named")
        try Expect.true(set.problems.contains { $0.contains("already the root 'team'") }, "Same directory twice")

        let mail = set.existing(.config("mail"))
        try Expect.equal(mail.map(\.root.name), ["team"], "Only roots that have the directory")
        try Expect.equal(RootLocation.agenticContext.description, ".agentic/context", "Context location")
    }

    static func invalid() throws {
        let directory = try scratch()
        let home = directory.appendingPathComponent("home", isDirectory: true)
        let file = home.appendingPathComponent(".config/roots.frame")
        try FrameFiles.write("import Roots;\nlet team: Root = .{ .paht = \"x\" };\n", to: file)
        let set = Roots.load(file: file, home: home)
        try Expect.equal(set.roots.map(\.name), ["private"], "Private still there")
        try Expect.false(set.problems.isEmpty, "The mistake is reported")
    }

    static func issues() throws {
        let directory = try scratch()
        let mail = directory.appendingPathComponent("team/.config/mail", isDirectory: true)
        for name in ["accounts.frame", "accounts 2.frame", "budget 2026.frame", ".access.frame.icloud", "notes.txt"] {
            try FrameFiles.write("", to: mail.appendingPathComponent(name))
        }
        try FrameFiles.write("", to: mail.appendingPathComponent("team/.providers.frame.icloud"))

        let issues = RootFileIssues.scan(mail)
        try Expect.equal(issues.conflictCopies.map(\.lastPathComponent), ["accounts 2.frame"], "Conflict copy beside its original only")
        try Expect.equal(issues.notDownloaded.map(\.lastPathComponent), ["access.frame", "providers.frame"], "Evicted files, nested too")
        try Expect.equal(issues.descriptions.count, 3, "One line each")
        try Expect.true(RootFileIssues.scan(directory.appendingPathComponent("missing")).isEmpty, "A missing directory has none")
    }
}
