import Foundation
import Frame
import GrammarParsing
import GrammarTreeSitter
import Position
import Testing

enum FrameTestSuite {
    static let suite = TestSuite("frame", title: "Frame language integration") {
        Test("bindings, object literals, members, arrays and references keep types and ranges") {
            let source = """
                // let is constant; var may be reassigned.
                let runtime = "AgenticRuntime";
                var workflow = .{
                    .package = runtime,
                    .enabled = true,
                    .skipped = null,
                    .retry = -2,
                    .timeout = 1.25,
                    .mode = .review,
                    .stages = [.{ .id = "runtime" }, .{ .id = "host", },],
                    .label = "é\\nnext",
                };
                """
            let document = try Frame.parse(source, filePath: "/repo/workflows.frame")
            try Expect.equal(document.bindings.map(\.name), ["runtime", "workflow"], "binding order")
            try Expect.equal(document.bindings[0].mutability, .constant, "let is constant")
            try Expect.equal(document.bindings[1].mutability, .variable, "var is variable")
            guard case .object(let fields) = document.bindings[1].value else {
                throw Frame.SyntaxFailure(.init("Expected an object literal"))
            }
            let ref = try Frame.Reference(components: ["runtime"])
            try Expect.equal(fields.map(\.name), ["package", "enabled", "skipped", "retry", "timeout", "mode", "stages", "label"], "field order")
            try Expect.equal(fields[0].value, .reference(ref), "reference stays typed")
            try Expect.equal(fields[1].value, .boolean(true), "boolean literal")
            try Expect.equal(fields[2].value, .null, "null literal")
            try Expect.equal(fields[3].value, .integer(-2), "negative integer")
            try Expect.equal(fields[4].value, .decimal(Decimal(125) / Decimal(100)), "decimal literal")
            try Expect.equal(fields[5].value, .member("review"), "implicit member")
            guard case .array(let stages) = fields[6].value else {
                throw Frame.SyntaxFailure(.init("Expected array"))
            }
            try Expect.equal(stages.count, 2, "object literals in arrays, trailing commas")
            try Expect.equal(fields[7].value, .string("é\nnext"), "string decoding")
            let workflowPackage = try Frame.Reference(components: ["workflow", "package"])
            try Expect.equal(try document.resolve(workflowPackage), .string("AgenticRuntime"), "accessor resolution")
            let map = Position.TextMap(source: source)
            let bytes = try map.range(document.bindings[1].range, as: Position.Unit.UTF8.self)
            try Expect.equal(bytes.upperBound.offset, source.utf8.count, "byte alignment")
        }

        Test("var reassignment replaces a value or one field; let refuses it") {
            let document = try Frame.parse("""
                var settings = .{ .paths = .{ .allow = ["a"] }, .log = .entry };
                settings.paths.deny = ["b"];
                settings.log = .batch;
                """)
            struct Paths: Decodable, Equatable { let allow: [String]; let deny: [String] }
            struct Settings: Decodable, Equatable { let paths: Paths; let log: String }
            let settings = try document.decode(Settings.self, binding: "settings")
            try Expect.equal(settings, .init(paths: .init(allow: ["a"], deny: ["b"]), log: "batch"), "reassigned fields")
            try Expect.throwsError("assigning a let") {
                _ = try Frame.parse("let a = 1; a = 2;")
            }
            try Expect.throwsError("assigning an undeclared name") {
                _ = try Frame.parse("a = 2;")
            }
            try Expect.throwsError("declaring twice") {
                _ = try Frame.parse("let a = 1; var a = 2;")
            }
        }

        Test("FrameCoding resolves references, reads members as strings and rejects unknown fields") {
            enum Mode: String, Decodable { case approval, review }
            struct Stage: Decodable, Equatable { let package: String; let test: String }
            struct Workflow: Decodable { let mode: Mode; let stages: [Stage] }
            let document = try Frame.parse("""
                let runtime = "AgenticRuntime";
                let workflow = .{ .mode = .review, .stages = [.{ .package = runtime, .test = "t_runtime" }] };
                """)
            let workflow = try document.decode(Workflow.self, binding: "workflow")
            try Expect.equal(workflow.mode, .review, "member decodes as a String-backed enum")
            try Expect.equal(workflow.stages, [.init(package: "AgenticRuntime", test: "t_runtime")], "resolved reference")
            try Expect.throwsError("references stay references when preserved") {
                _ = try document.decode(Workflow.self, binding: "workflow", using: .init(references: .preserve))
            }
            let typo = try Frame.parse("let workflow = .{ .mode = .review, .stages = [], .stagse = [] };")
            try Expect.throwsError("unknown field") {
                _ = try typo.decode(Workflow.self, binding: "workflow")
            }
            _ = try typo.decode(Workflow.self, binding: "workflow", using: .init(unknownFields: .ignore))
        }

        Test("imports name registered modules; annotated bindings are checked against their type") {
            struct PathScope: Decodable { let path: String; let sessions: String }
            let module = Frame.Module("agentic", types: [.decodable(PathScope.self, named: "PathScope")])
            let environment = Frame.Environment([module])
            let valid = try Frame.parse("""
                import agentic;
                let notes: PathScope = .{ .path = "~/notes", .sessions = .all };
                let qualified: agentic.PathScope = .{ .path = "~/x", .sessions = .all };
                """, environment: environment)
            try Expect.equal(valid.bindings(ofType: "PathScope").map(\.name), ["notes", "qualified"], "typed bindings")
            for (label, source) in [
                ("unknown module", "import nothing;"),
                ("type without import", "let a: PathScope = .{ .path = \"x\", .sessions = .all };"),
                ("unknown type", "import agentic; let a: Nope = 1;"),
                ("missing field", "import agentic; let a: PathScope = .{ .path = \"x\" };"),
                ("unknown field", "import agentic; let a: PathScope = .{ .path = \"x\", .sessions = .all, .extra = 1 };"),
                ("wrong kind", "import agentic; let a: PathScope = .{ .path = 1, .sessions = .all };"),
            ] {
                try Expect.throwsError(label) { _ = try Frame.parse(source, environment: environment) }
            }
            do {
                _ = try Frame.parse("import agentic;\nlet a: PathScope = .{ .path = 1, .sessions = .all };", environment: environment)
            } catch let failure as Frame.TypeFailure {
                try Expect.true(failure.description.hasPrefix("2:") && failure.message.contains("a.path"),
                                "the failure names the line and the field: \(failure)")
            }
        }

        Test("syntax failures") {
            let invalid = [
                "let name = \"missing-semicolon\"",
                "let names = [\"a\" \"b\"];",
                "let name = [1, 2;",
                "let name = \"bad\\q\";",
                "let package = packages.;",
                "let config = { .x = true };",
                "let config = .{ x = true };",
                "let config = .{ .x: true };",
                "let value = 01;",
                "import;",
                "let a: = 1;",
                "# hash comments are gone\nlet a = 1;",
            ]
            for (index, source) in invalid.enumerated() {
                try Expect.throwsError("invalid Frame fixture \(index)") {
                    _ = try Frame.parse(source)
                }
            }
            try Expect.equal(try Frame.parse("let name = \"ok\"; // fine").bindings.count, 1, "valid")
            let cyclic = try Frame.parse("let a = b; let b = a;")
            try Expect.throwsError("reference cycle") { _ = try cyclic.resolve(try Frame.Reference(components: ["a"])) }
        }

        Test("native parser and generated Tree-sitter recognize identical Frame syntax") {
            try FrameParity.run()
        }
    }
}

private enum FrameParity {
    static func run() throws {
        let language = try Frame.language()
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("frame-grammar-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let src = workspace.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        let artifacts = try GrammarTreeSitter.emit(language)
        let repeated = try GrammarTreeSitter.emit(language)
        try Expect.equal(artifacts.grammarJSON, repeated.grammarJSON, "deterministic grammar export")
        try Expect.equal(artifacts.queries, repeated.queries, "deterministic highlight export")
        try write(artifacts.grammarJSON, at: src.appendingPathComponent("grammar.json"))
        guard let highlights = artifacts.queries["highlights.scm"] else {
            throw Frame.SyntaxFailure(.init("Frame highlights.scm was not generated"))
        }
        let queryDirectory = workspace.appendingPathComponent("queries", isDirectory: true)
        try FileManager.default.createDirectory(at: queryDirectory, withIntermediateDirectories: true)
        let queryPath = queryDirectory.appendingPathComponent("highlights.scm")
        try write(highlights, at: queryPath)
        try write(#"{"name":"tree-sitter-frame","version":"0.1.0"}"#,
                  at: workspace.appendingPathComponent("package.json"))
        let metadata = #"""
        {
            "grammars": [{
                "name": "frame",
                "scope": "source.frame",
                "path": ".",
                "file-types": ["frame"]
            }],
            "metadata": { "version": "0.1.0", "authors": [{"name": "Frame Conformance"}] }
        }
        """#
        try write(metadata, at: workspace.appendingPathComponent("tree-sitter.json"))
        let generated = try command(["generate", "src/grammar.json"], in: workspace)
        try Expect.equal(generated.status, 0, "Tree-sitter generation: \(generated.output)")
        let settingsFixture = """
            // settings.frame
            import agentic;

            let notes: PathScope = .{
                .path = "~/notes/**",
                .sessions = .all,
            };

            /* every field in one place */
            var settings: agentic.AgenticSettings = .{
                .paths = .{ .allow = [], .ask = [notes], .deny = [] },
                .mutations = .{ .publication = .review },
                .retries = 3,
                .ratio = -0.5,
                .enabled = true,
                .missing = null,
            };
            settings.paths.deny = ["~/.ssh"];
            """
        let settingsURL = workspace.appendingPathComponent("settings.frame")
        try write(settingsFixture, at: settingsURL)
        _ = try Frame.parse(settingsFixture)
        let settingsParse = try command(["parse", "--grammar-path", workspace.path, settingsURL.path], in: workspace)
        try Expect.equal(settingsParse.status, 0, "Tree-sitter settings.frame parsing: \(settingsParse.output)")
        try Expect.true(!settingsParse.output.contains("(ERROR") && !settingsParse.output.contains("(MISSING"),
                        "complete Tree-sitter syntax tree")
        let query = try command(["query", "--grammar-path", workspace.path,
                                 queryPath.path, settingsURL.path], in: workspace)
        try Expect.equal(query.status, 0, "Tree-sitter highlights query: \(query.output)")
        for capture in ["keyword", "namespace", "type", "property", "variable", "constant", "boolean",
                        "constant.builtin", "string", "number", "comment", "operator",
                        "punctuation.bracket", "punctuation.delimiter"] {
            try Expect.true(query.output.contains(capture), "highlight capture \(capture)")
        }
        let native = try GrammarParser(language: language)
        let samples: [(String, Bool)] = [
            ("let name = \"Frame\";", true),
            ("import agentic;", true),
            ("let scope: agentic.PathScope = .{ .path = \"x\" };", true),
            ("var a = .{ .b = .{ .c = 1 } }; a.b.c = 2;", true),
            ("let values = [1, 2, 3,];", true),
            ("let stages = [.{ .id = \"a\" }, .{ .id = \"b\", }];", true),
            ("let mode = .review;", true),
            ("let threshold = -1.25;", true),
            ("let empty = []; let object = .{};", true),
            ("// line\nlet name = true;", true),
            ("/* block */ let name = null;", true),
            ("let package = packages.agentic.runtime;", true),
            ("let name = \"missing semicolon\"", false),
            ("let names = [\"a\" \"b\"];", false),
            ("let package = packages.;", false),
            ("let object = { .a = 1 };", false),
            ("let object = .{ a = 1 };", false),
            ("name { a = 1; }", false),
            ("# hash\nlet name = false;", false),
        ]
        for (index, fixture) in samples.enumerated() {
            let path = workspace.appendingPathComponent("case-\(index).frame")
            try write(fixture.0, at: path)
            let nativeAccepted = (try? native.parse(fixture.0)) != nil
            let parsed = try command(["parse", "--grammar-path", workspace.path, path.path], in: workspace)
            let sitterAccepted = parsed.status == 0
                && !parsed.output.contains("(ERROR")
                && !parsed.output.contains("(MISSING")
            try Expect.equal(nativeAccepted, fixture.1, "native fixture \(index)")
            try Expect.equal(sitterAccepted, fixture.1, "Tree-sitter fixture \(index): \(parsed.output)")
        }
    }

    static func write(_ text: String, at path: URL) throws {
        try text.write(to: path, atomically: true, encoding: .utf8)
    }

    static func command(_ arguments: [String], in workspace: URL) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["tree-sitter"] + arguments
        process.currentDirectoryURL = workspace
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        return (process.terminationStatus,
                String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    }
}
