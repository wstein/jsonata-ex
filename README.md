# JSONata for Elixir

A native Elixir port of [JSONata](https://jsonata.org/), the JSON query and
transformation language. This is a clean-room reimplementation tracking the
reference implementation [`jsonata-js`](https://github.com/jsonata-js/jsonata)
v2.2.1, validated against its language-agnostic conformance suite.

> **Status: under construction.** The project is being built phase by phase
> (see `../IMPLEMENTATION_PLAN.md` and `../MIGRATION.md`). The tokenizer and core
> data model are implemented; the parser, evaluator, and function library are
> the next phases. There is no public `evaluate/2` yet.

## Architecture

| Module | Responsibility |
|--------|----------------|
| `Jsonata.Tokenizer` | Binary-pattern-matching lexer (JSONata token grammar) |
| `Jsonata.Token` | Token struct |
| `Jsonata.AST` | Typed AST node structs produced by the parser |
| `Jsonata.Sequence` | The JSONata sequence data model (`Enumerable`, eager/lazy-ready) |
| `Jsonata.Value` | Type predicates and the "nothing" value (`:undefined` vs JSON `nil`) |
| `Jsonata.Error` | JSONata error codes (`S0xxx`, `T0xxx`, `D0xxx`) |
| `Jsonata.Conformance` | Loader for the upstream JSON conformance suite |

## Development

```bash
mix deps.get
mix compile --warnings-as-errors
mix format --check-formatted
mix credo --strict
mix test --cover
```

The conformance suite lives in the sibling `jsonata` submodule. When present,
`Jsonata.Conformance.load/0` enumerates every upstream case; integration tests
that depend on it skip gracefully when the submodule is not checked out.

## License

MIT.
