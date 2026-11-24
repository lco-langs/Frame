import enum Grammar.Grammar

public enum Frame {
    /// A single grammar drives native recognition and Tree-sitter export.
    ///
    ///     import Agentic;
    ///     let scope: PathScope = .{ .path = "~/notes", .sessions = .all, };
    ///     let limit: Size = .gigabytes(2.5);
    ///     var settings: AgenticSettings = .{ .paths = .{ .ask = [scope] } };
    ///     settings.paths.deny = [];
    ///
    /// Bindings, imports and assignments around the shared value syntax (`valueGrammar()`).
    public static func language() throws -> Grammar.Language {
        let values = valueGrammar()
        let identifier = Grammar.Expression.symbol(.terminal("identifier"))
        let value = Grammar.Expression.symbol(.production("value"))
        return try Grammar.Language(
            name: "frame",
            start: "document",
            productions: [
                .init(name: "document", expression: .repeat0(.choice([
                    .symbol(.production("import")),
                    .symbol(.production("binding")),
                    .symbol(.production("assignment"))
                ]))),
                // Makes a registered module's types nameable.
                .init(name: "import", expression: .sequence([
                    .symbol(.terminal("import_keyword")),
                    .field("module", identifier),
                    .literal(";")
                ])),
                // `let` is a constant; a `var` may be reassigned later.
                .init(name: "binding", expression: .sequence([
                    .field("mutability", .choice([
                        .symbol(.terminal("let_keyword")),
                        .symbol(.terminal("var_keyword"))
                    ])),
                    .field("name", identifier),
                    .optional(.sequence([
                        .literal(":"),
                        .field("type", .symbol(.production("type")))
                    ])),
                    .literal("="),
                    .field("value", value),
                    .literal(";")
                ])),
                // Reassigns a `var`, or one field inside it.
                .init(name: "assignment", expression: .sequence([
                    .field("target", .symbol(.production("reference"))),
                    .literal("="),
                    .field("value", value),
                    .literal(";")
                ]))
            ] + values.productions,
            terminals: values.terminals + [
                .init(name: "import_keyword", pattern: .literal("import"), lexicalPriority: 1, role: "keyword"),
                .init(name: "let_keyword", pattern: .literal("let"), lexicalPriority: 1, role: "keyword"),
                .init(name: "var_keyword", pattern: .literal("var"), lexicalPriority: 1, role: "keyword")
            ],
            extras: values.extras,
            highlights: [
                .field(production: "binding", name: "name", role: "variable"),
                .field(production: "import", name: "module", role: "namespace")
            ] + values.highlights + [
                .literal(":", role: "punctuation.delimiter"),
                .literal(";", role: "punctuation.delimiter")
            ]
        )
    }
}
