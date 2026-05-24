# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); the project follows
[Semantic Versioning](https://semver.org/).

## [Unreleased]

A native Elixir port of [JSONata](https://jsonata.org/) v2.2.1, validated against
the upstream language-agnostic conformance suite (~75% of specified cases pass).

### Added

- **Parser** — `Jsonata.compile/1`, the `~J` compile-time sigil, and a Pratt
  parser (`Jsonata.Parser`) producing a tagged-map AST. Lexer (`Jsonata.Tokenizer`)
  uses binary pattern matching and emits upstream lexical error codes.
- **Evaluator** — paths/steps with the flatten and singleton-collapse rules,
  predicates, all binary/unary operators, ranges, conditionals (`? :`, `?:`, `??`),
  blocks, variable binds, array/object constructors, wildcards, and descendants.
- **Functions & lambdas** — ~50 built-ins with signature validation
  (`Jsonata.Signature`), lambdas with closures and self-recursion, higher-order
  functions (`$map`/`$filter`/`$reduce`/`$single`/`$sift`/`$each`, comparator
  `$sort`), the `~>` apply/compose operator, and partial application (`?`).
- **Operators** — regex matchers (`$match` and the regex forms of
  `$contains`/`$split`/`$replace`), order-by `^`, group-by `{`, and the
  positional tuple-stream operators focus `@` / index `#` (joins).
- **Date/time** — `$fromMillis`/`$toMillis` (ISO 8601), `$now`/`$millis`, and
  `$formatBase`.
- **Picture strings** — `$formatInteger` (`Jsonata.Format`): decimal patterns
  with regular and irregular grouping separators, the `;o` ordinal modifier,
  Roman numerals (`i`/`I`), letter sequences (`a`/`A`), and spelled-out words
  (`w`/`W`/`Ww`). Non-ASCII digit groups and numbers ≥ 10⁴⁶ as words are not yet
  supported.
- **Host integration** — `$eval`, and registering Elixir functions as callable
  `$fn` via `Jsonata.evaluate/3` bindings.
- **Tooling** — `credo --strict`, `dialyzer` (clean), 90%+ test coverage, and
  StreamData property tests, all enforced in CI.

### Not yet implemented

- Date/time and numeric **picture strings** (`$formatNumber`/`$formatInteger`/
  `$parseInteger`, picture-string `$fromMillis`/`$toMillis`).
- The **parent operator** `%`, the **transform** `|…|` operator, and
  order-sensitive object key handling (`$keys`/`$spread`/`$each`).
- JavaScript-style **async** functions (out of scope for the synchronous engine).
