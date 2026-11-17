import enum Grammar.Grammar

public enum Frame {
    /// A single grammar drives native recognition and Tree-sitter export.
    ///
    ///     import Agentic;
    ///     let scope: PathScope = .{ .path = "~/notes", .sessions = .all, };
    ///     var settings: AgenticSettings = .{ .paths = .{ .ask = [scope] } };
    ///     settings.paths.deny = [];
    public static func language() throws -> Grammar.Language {
        let identifier = Grammar.Expression.symbol(.terminal("identifier"))
        let value = Grammar.Expression.symbol(.production("value"))
        let path = Grammar.Expression.sequence([
            identifier,
            .repeat0(.sequence([.literal("."), identifier]))
        ])
        func list(_ item: String, _ rest: String) -> Grammar.Expression {
            .sequence([
                .symbol(.production(item)),
                .optional(.sequence([
                    .literal(","),
                    .optional(.symbol(.production(rest)))
                ]))
            ])
        }
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
                ])),
                .init(name: "type", expression: path),
                .init(name: "value", expression: .choice([
                    .symbol(.terminal("quoted")),
                    .symbol(.terminal("block_quoted")),
                    .symbol(.terminal("number")),
                    .symbol(.terminal("boolean")),
                    .symbol(.terminal("null")),
                    .symbol(.production("literal")),
                    .symbol(.production("array")),
                    .symbol(.production("reference")),
                    .symbol(.production("member"))
                ])),
                // An object of the expected type: `.{ .name = value, }`.
                .init(name: "literal", expression: .sequence([
                    .literal("."),
                    .literal("{"),
                    .optional(.symbol(.production("fields"))),
                    .literal("}")
                ])),
                .init(name: "fields", expression: list("field", "fields")),
                .init(name: "field", expression: .sequence([
                    .literal("."),
                    .field("name", identifier),
                    .literal("="),
                    .field("value", value)
                ])),
                // A member of the expected type, e.g. `.review` or `.all`.
                .init(name: "member", expression: .sequence([
                    .literal("."),
                    .field("name", identifier)
                ])),
                .init(name: "array", expression: .sequence([
                    .literal("["),
                    .optional(.symbol(.production("array_items"))),
                    .literal("]")
                ])),
                .init(name: "array_items", expression: .sequence([
                    .field("element", value),
                    .optional(.sequence([
                        .literal(","),
                        .optional(.symbol(.production("array_items")))
                    ]))
                ])),
                .init(name: "reference", expression: path)
            ],
            terminals: [
                .init(name: "quoted", pattern: .regex(#""([^"\\]|\\.)*""#), role: "string"),
                // Spans lines; a run of one or two quotes may occur inside, three end it.
                .init(name: "block_quoted", pattern: .regex(#""""([^"\\]|\\.|""?([^"\\]|\\.))*""""#), role: "string"),
                .init(name: "number", pattern: .regex(#"-?(0|[1-9][0-9]*)(\.[0-9]+)?"#), role: "number"),
                .init(name: "identifier", pattern: .regex(#"[\p{L}_][\p{L}\p{N}_-]*"#)),
                .init(name: "boolean", pattern: .regex(#"true|false"#), lexicalPriority: 1, role: "boolean"),
                .init(name: "null", pattern: .literal("null"), lexicalPriority: 1, role: "constant.builtin"),
                .init(name: "import_keyword", pattern: .literal("import"), lexicalPriority: 1, role: "keyword"),
                .init(name: "let_keyword", pattern: .literal("let"), lexicalPriority: 1, role: "keyword"),
                .init(name: "var_keyword", pattern: .literal("var"), lexicalPriority: 1, role: "keyword"),
                .init(name: "line_comment", pattern: .regex(#"//[^\r\n]*"#), role: "comment"),
                .init(name: "block_comment", pattern: .regex(#"/\*([^*]|\*+[^*/])*\*+/"#), role: "comment")
            ],
            extras: [
                .pattern(#"[ \t\r\n]+"#),
                .symbol(.terminal("line_comment")),
                .symbol(.terminal("block_comment"))
            ],
            highlights: [
                .field(production: "binding", name: "name", role: "variable"),
                .field(production: "import", name: "module", role: "namespace"),
                .field(production: "field", name: "name", role: "property"),
                .field(production: "member", name: "name", role: "constant"),
                .symbol(.terminal("identifier"), within: "type", role: "type"),
                .symbol(.terminal("identifier"), within: "reference", role: "variable"),
                .literal("=", role: "operator"),
                .literal(".", role: "operator"),
                .literal(":", role: "punctuation.delimiter"),
                .literal("{", role: "punctuation.bracket"),
                .literal("}", role: "punctuation.bracket"),
                .literal("[", role: "punctuation.bracket"),
                .literal("]", role: "punctuation.bracket"),
                .literal(";", role: "punctuation.delimiter"),
                .literal(",", role: "punctuation.delimiter")
            ]
        )
    }
}
