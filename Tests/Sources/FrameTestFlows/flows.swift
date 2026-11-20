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

        Test("a call is a one-field object: .name(value), several arguments as an array, none as a member") {
            let document = try Frame.parse("""
                let limits = .{
                    .size = .gigabytes(2.5),
                    .range = .between(1, 2,),
                    .plain = .none(),
                    .nested = .wrap(.{ .a = 1 }),
                    .spelled = .{ .gigabytes = 2.5 },
                };
                """)
            guard case .object(let fields) = document.bindings[0].value else {
                throw Frame.SyntaxFailure(.init("Expected an object literal"))
            }
            func field(_ value: Frame.Value) -> [String] {
                guard case .object(let inner) = value else { return [] }
                return inner.map(\.name)
            }
            try Expect.equal(field(fields[0].value), ["gigabytes"], "one argument")
            guard case .object(let size) = fields[0].value, case .object(let spelled) = fields[4].value else {
                throw Frame.SyntaxFailure(.init("Expected objects"))
            }
            try Expect.equal(size[0].value, spelled[0].value, "the call means the same as the spelled-out object")
            guard case .object(let range) = fields[1].value else { throw Frame.SyntaxFailure(.init("Expected object")) }
            try Expect.equal(range[0].value, .array([.integer(1), .integer(2)]), "several arguments, trailing comma")
            try Expect.equal(fields[2].value, .member("none"), "no arguments is the member")
            try Expect.equal(field(fields[3].value), ["wrap"], "an object argument")

            struct Size: Decodable, Equatable { let gigabytes: Double }
            struct Limits: Decodable { let size: Size; let spelled: Size }
            let sizes = try Frame.parse("let limits = .{ .size = .gigabytes(2.5), .spelled = .{ .gigabytes = 2.5 } };")
            let limits = try sizes.decode(Limits.self, binding: "limits")
            try Expect.equal(limits.size, limits.spelled, "decodes like the object")

            let grammar = try GrammarTreeSitter.emit(Frame.language()).grammarJSON
            try Expect.true(grammar.contains("\"call\""), "the call production reaches the tree-sitter grammar")
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

        Test("block strings span lines and drop the closing indentation") {
            let document = try Frame.parse("""
                let details = \"\"\"
                    First line, "quoted" and ""twice"".

                      indented \\u{e9}
                    \"\"\";
                let empty = \"\"\"
                    \"\"\";
                let inline = \"\"\"one line\"\"\";
                let tail = "x\\u{e9}";
                """)
            try Expect.equal(document.binding(named: "tail")?.value, .string("xé"), "escape at the end of a string")
            try Expect.equal(document.binding(named: "details")?.value,
                             .string("First line, \"quoted\" and \"\"twice\"\".\n\n  indented é"), "dedented block")
            try Expect.equal(document.binding(named: "empty")?.value, .string(""), "empty block")
            try Expect.equal(document.binding(named: "inline")?.value, .string("one line"), "single-line block")
            try Expect.throwsError("a line indented less than the closing quotes") {
                _ = try Frame.parse("let a = \"\"\"\n  text\n    \"\"\";")
            }
            try Expect.throwsError("an unterminated block") {
                _ = try Frame.parse("let a = \"\"\"\n  text\n;")
            }
        }

        Test("described types carry a schema that editors can walk") {
            enum Show: String, Decodable, CaseIterable, Sendable { case full, relativeToBase }
            struct Include: Decodable, Sendable, FrameDescribable {
                let from: String
                let show: Show
                static let frameSchema = Frame.Schema.object([
                    .init("from", .string, required: true, summary: "Base directory."),
                    .init("show", .members(of: Show.self)),
                ])
            }
            struct Output: Decodable, Sendable, FrameDescribable {
                let include: [Include]
                static let frameSchema = Frame.Schema.object([.init("include", .array(.of(Include.self)))],
                                                             summary: "One concatenated file.")
            }
            let module = Frame.Module("Concatenation", types: [
                .decodable(Output.self, named: "Output"),
                .decodable(Show.self, named: "Show"),
            ])
            let schema = try Expect.notNil(module.types[0].schema, "a FrameDescribable type has a schema")
            try Expect.equal(schema.summary, "One concatenated file.", "summary")
            try Expect.equal(schema.schema(at: ["include", "from"])?.properties.count, 0, "array elements are transparent")
            try Expect.equal(schema.schema(at: ["include"])?.schema(at: ["show"])?.members.map(\.name),
                             ["full", "relativeToBase"], "enum members")
            try Expect.equal(schema.schema(at: ["include", "nope"]) == nil, true, "unknown field")
            try Expect.equal(module.types[1].schema == nil, true, "a plain Decodable has none")
        }

        Test("encoded values render as Frame source that decodes back to the same values") {
            enum Mode: String, Codable, Equatable { case review, approval }
            struct Stage: Codable, Equatable { let id: String; let retries: Int }
            struct Workflow: Codable, Equatable {
                let mode: Mode
                let stages: [Stage]
                let ratio: Double
                let budget: Decimal
                let note: String?
                let details: String
                let labels: [String: String]
                let flags: [Bool]
            }
            let workflow = Workflow(
                mode: .review,
                stages: [.init(id: "runtime", retries: 2), .init(id: "host \"main\"\t", retries: -1)],
                ratio: 0.1, budget: Decimal(string: "12.50")!, note: nil,
                details: "First \"line\".\n\n  indented\\path\nhas \"\"\" inside\n",
                labels: ["zeta": "z", "alpha": "a"], flags: []
            )
            let document = try Frame.document(bindings: [(name: "workflow", type: nil, value: workflow)])
            let source = document.source
            try Expect.true(source.contains(".mode = .review,"), "an enum renders as a member:\n\(source)")
            try Expect.true(source.contains(".labels = .{ .alpha = \"a\", .zeta = \"z\" },"), "sorted dictionary keys:\n\(source)")
            try Expect.true(source.contains(".details = \"\"\"\n"), "multi-line text renders as a block:\n\(source)")
            try Expect.true(!source.contains(".note"), "nil is left out")
            let decoded = try Frame.parse(source).decode(Workflow.self, binding: "workflow")
            try Expect.equal(decoded, workflow, "round trip:\n\(source)")
            try Expect.equal(try Frame.parse(source).source, source, "rendering is stable")
            try Expect.throwsError("a field name that is not an identifier") {
                _ = try FrameEncoder().encode(["not a name": 1])
            }
            try Expect.throwsError("a number Frame cannot write") { _ = try FrameEncoder().encode(Double.nan) }
        }

        Test("a module's schema is written as a module file and read back") {
            enum Show: String, Decodable, CaseIterable, Sendable, FrameDescribable { case full, relativeToBase }
            struct Include: Decodable, Sendable, FrameDescribable {
                static let frameSchema = Frame.Schema.object([
                    .init("from", .string, required: true, summary: "Base directory."),
                    .init("show", .of(Show.self)),
                    .init("paths", .array(.string)),
                ])
            }
            struct Output: Decodable, Sendable, FrameDescribable {
                static let frameSchema = Frame.Schema.object([
                    .init("path", .string, required: true),
                    .init("include", .array(.of(Include.self))),
                    .init("depth", .integer),
                ], summary: "One concatenated file.")
            }
            let module = Frame.Module("Concatenation", types: [
                .decodable(Show.self, named: "Show"),
                .decodable(Include.self, named: "Include"),
                .decodable(Output.self, named: "Output"),
            ])
            let source = try module.document().source
            try Expect.true(source.hasPrefix("import Frame;\n\nlet Show: Type = .{ .members = [.full, .relativeToBase] };"),
                            "header and members:\n\(source)")
            try Expect.true(source.contains(".type = Show") && source.contains(".array = Include"),
                            "nested types are written by name:\n\(source)")
            let parsed = try Frame.parse(source, environment: .init([.frame]))
            let types = try Frame.Schema.types(in: parsed)
            try Expect.equal(types.map(\.name), ["Show", "Include", "Output"], "type names")
            try Expect.equal(types.map(\.schema), module.types.compactMap(\.schema), "schemas survive the round trip")
            for (label, fixture) in [
                ("unknown scalar", "import Frame; let A: Type = .{ .properties = [.{ .name = \"a\", .type = .strng }] };"),
                ("two shapes", "import Frame; let A: Type = .{ .members = [], .properties = [] };"),
                ("unknown field", "import Frame; let A: Type = .{ .propertes = [] };"),
            ] {
                try Expect.throwsError(label) { _ = try Frame.parse(fixture, environment: .init([.frame])) }
            }
        }

        Test("the schema of module files is itself a module file") {
            let source = try Frame.Module.frame.document().source
            let parsed = try Frame.parse(source, environment: .init([.frame]))
            try Expect.equal(try Frame.Schema.types(in: parsed).map(\.schema), [Frame.Schema.frameSchema],
                             "self-description round trip:\n\(source)")
        }

        Test("a schema reports every problem at its field") {
            let module = try Frame.Module("Concatenation", loading: Frame.parse("""
                import Frame;
                let Show: Type = .{ .members = [.full, .relativeToBase] };
                let Include: Type = .{ .properties = [
                    .{ .name = "from", .type = .string, .required = true },
                    .{ .name = "show", .type = Show },
                    .{ .name = "depth", .type = .integer },
                    .{ .name = "paths", .type = .{ .array = .string } },
                ] };
                """, environment: .init([.frame])))
            let environment = Frame.Environment([module])
            let source = """
                import Concatenation;
                let names = ["a", 2];
                let include: Include = .{
                    .show = .basename,
                    .depth = "deep",
                    .paths = names,
                    .exclude = [],
                };
                let fine: Include = .{ .from = "$CWD", .show = .full };
                """
            let document = try Frame.parse(source)
            let problems = Frame.problems(in: document, environment: environment).map { $0.located(in: source) }
            try Expect.equal(problems.map(\.message), [
                "'include.show': unknown member '.basename'; expected .full, .relativeToBase",
                "'include.depth' expects an integer, found a string",
                "'include.paths[1]' expects a string, found an integer",
                "'include': unknown field 'exclude'",
                "'include': missing field 'from'",
            ], "every problem, in source order")
            try Expect.equal(problems.compactMap(\.line), [4, 5, 6, 7, 3], "each at its field, a missing one at its binding")
            try Expect.throwsError("parsing with the environment still fails") {
                _ = try Frame.parse(source, environment: environment)
            }
        }

        Test("an outdated schema misleads only the editor, never the program") {
            struct Paths: Codable, Sendable, FrameDescribable {
                var allow: [String] = []
                var deny: [String] = []
                static let frameSchema = Frame.Schema.object([.init("allow", .array(.string))])
            }
            let environment = Frame.Environment([Frame.Module("Agentic", types: [.decodable(Paths.self, named: "Paths")])])
            let source = "import Agentic; let paths: Paths = .{ .allow = [], .deny = [\"~/.ssh\"] };"
            _ = try Frame.parse(source, environment: environment)
            try Expect.equal(Frame.problems(in: try Frame.parse(source), environment: environment).count, 1,
                             "the editor reports the field the schema lacks")
            try Expect.equal(try Paths.frameSchemaProblems(in: Paths(deny: ["x"])).map(\.message),
                             ["'Paths': unknown field 'deny'"], "the drift test catches it")
        }

        Test("module files load from a directory; a broken one does not stop the rest") {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("frame-modules-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            try "import Frame;\nlet Mode: Type = .{ .members = [.review] };\n"
                .write(to: directory.appendingPathComponent("Agentic.frame"), atomically: true, encoding: .utf8)
            try "import Frame;\nlet Broken: Type = .{ .members = 1 };\n"
                .write(to: directory.appendingPathComponent("Broken.frame"), atomically: true, encoding: .utf8)
            try "not frame".write(to: directory.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
            let installed = try Frame.Module("Concatenation", types: [
                .described(.init(.members([.init("full")])), named: "Show"),
            ]).install(into: directory)
            try Expect.equal(installed.lastPathComponent, "Concatenation.frame", "installed by module name")
            let loaded = Frame.Environment.loading(modulesIn: directory)
            try Expect.equal(loaded.environment.modules.map(\.name), ["Frame", "Agentic", "Concatenation"],
                             "modules by file name")
            _ = try Frame.parse("import Concatenation; let show: Show = .full;", environment: loaded.environment)
            try Expect.equal(loaded.failures.map(\.file.lastPathComponent), ["Broken.frame"], "the broken file")
            _ = try Frame.parse("import Agentic; let mode: Mode = .review;", environment: loaded.environment)
            try Expect.throwsError("a loaded type checks by its schema") {
                _ = try Frame.parse("import Agentic; let mode: Mode = .approval;", environment: loaded.environment)
            }
            try Expect.equal(Frame.Environment.loading(modulesIn: directory.appendingPathComponent("none"))
                .environment.modules.map(\.name), ["Frame"], "no directory, no modules")
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
                .notes = \"\"\"
                    Spans "lines".
                    \"\"\",
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
            ("let text = \"\"\"\n    a \"b\" \"\"c\"\"\n    \"\"\";", true),
            ("let text = \"\"\"inline\"\"\"; let next = \"x\";", true),
            ("let a = \"\"\"x\"\"\"; let b = \"\"\"y\"\"\";", true),
            ("let text = \"\"\"\n    unterminated\n;", false),
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
