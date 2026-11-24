import enum Grammar.Grammar

public extension Frame {
    /// Frame's value syntax, for another `Grammar.Language` to embed: strings, block strings,
    /// numbers, booleans, `null`, object literals `.{ .name = value }`, members `.name`,
    /// calls `.name(value)`, arrays, references and type paths, with Frame's identifiers,
    /// comments and whitespace.
    ///
    /// A host language adds its own productions and keywords and refers to the productions
    /// `value` (any value) and `type` (a type path). Its keywords need `lexicalPriority: 1`
    /// so they win over `identifier`, as Frame's own `import`, `let` and `var` do. Highlights
    /// cover only tokens the value syntax uses; the host highlights its own (Frame: `:` `;`).
    struct ValueGrammar: Sendable {
        public let productions: [Grammar.Production]
        public let terminals: [Grammar.Terminal]
        public let extras: [Grammar.Expression]
        public let highlights: [Grammar.Highlight]
    }

    static func valueGrammar() -> ValueGrammar {
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
        return ValueGrammar(
            productions: [
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
                    .symbol(.production("call")),
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
                // A member with arguments, e.g. `.gigabytes(2.5)`: shorthand for the one-field
                // object `.{ .gigabytes = 2.5 }` (several arguments make the field an array).
                .init(name: "call", expression: .sequence([
                    .literal("."),
                    .field("name", identifier),
                    .literal("("),
                    .optional(.symbol(.production("array_items"))),
                    .literal(")")
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
                .init(name: "line_comment", pattern: .regex(#"//[^\r\n]*"#), role: "comment"),
                .init(name: "block_comment", pattern: .regex(#"/\*([^*]|\*+[^*/])*\*+/"#), role: "comment")
            ],
            extras: [
                .pattern(#"[ \t\r\n]+"#),
                .symbol(.terminal("line_comment")),
                .symbol(.terminal("block_comment"))
            ],
            highlights: [
                .field(production: "field", name: "name", role: "property"),
                .field(production: "member", name: "name", role: "constant"),
                .field(production: "call", name: "name", role: "function"),
                .symbol(.terminal("identifier"), within: "type", role: "type"),
                .symbol(.terminal("identifier"), within: "reference", role: "variable"),
                .literal("=", role: "operator"),
                .literal(".", role: "operator"),
                .literal("{", role: "punctuation.bracket"),
                .literal("}", role: "punctuation.bracket"),
                .literal("[", role: "punctuation.bracket"),
                .literal("]", role: "punctuation.bracket"),
                .literal("(", role: "punctuation.bracket"),
                .literal(")", role: "punctuation.bracket"),
                .literal(",", role: "punctuation.delimiter")
            ]
        )
    }
}
