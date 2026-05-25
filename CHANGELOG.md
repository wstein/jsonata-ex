# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); the project follows
[Semantic Versioning](https://semver.org/).

## [Unreleased]

A native Elixir port of [JSONata](https://jsonata.org/) v2.2.1, validated against
the upstream language-agnostic conformance suite (~96% of specified cases pass).

### Added

- **Parser** — `Jsonata.compile/1`, the `~J` compile-time sigil, and a Pratt
  parser (`Jsonata.Parser`) producing a tagged-map AST. Lexer (`Jsonata.Tokenizer`)
  uses binary pattern matching and emits upstream lexical error codes.
- **Evaluator** — paths/steps with the flatten and singleton-collapse rules,
  predicates, all binary/unary operators, ranges, conditionals (`? :`, `?:`, `??`),
  blocks, variable binds, array/object constructors, wildcards, and descendants.
- **Functions & lambdas** — ~50 built-ins with signature validation
  (`Jsonata.Signature`), including `$shuffle`; `$number` parses hex/binary/octal
  literals; `$round`/`$formatBase` use decimal-correct round-half-to-even;
  lambdas with closures and self-recursion; higher-order functions
  (`$map`/`$filter`/`$reduce`/`$single`/`$sift`/`$each`, comparator `$sort`); the
  `~>` apply/compose operator; partial application (`?`); and chained assignment
  (`$a := $b := 5` binds both).
- **Operators** — regex matchers (`$match` and the regex forms of
  `$contains`/`$split`/`$replace`), order-by `^`, group-by `{`, the positional
  tuple-stream operators focus `@` / index `#` (joins), the parent operator
  `%` — the slot/ancestry resolution that binds an ancestor step's context
  through the tuple stream (including through blocks and predicates) — and the
  transform `|pattern|update[,delete]|` operator (`T2011`/`T2012` validation).
- **Date/time** — `$fromMillis`/`$toMillis` (ISO 8601), `$now`/`$millis`, and
  `$formatBase`. Date/time picture-string formatting **and parsing**
  (`$fromMillis`/`$now`/`$toMillis`, `Jsonata.DateTimePicture`): the
  `[Y0001]-[M01]-[D01]` component grammar with presentation/width modifiers,
  month/day names, ordinals, spelled-out words, day-of-year, ISO week numbers,
  am/pm, and timezone offsets. `$toMillis` also accepts partial ISO 8601 forms
  (date-only, year-only).
- **Picture strings** — `$formatInteger` and `$parseInteger` (`Jsonata.Format`):
  decimal patterns with regular and irregular grouping separators, the `;o`
  ordinal modifier, Roman numerals (`i`/`I`), letter sequences (`a`/`A`), and
  spelled-out words (`w`/`W`/`Ww`). Non-ASCII digit groups and numbers ≥ 10⁴⁶ are
  not yet supported. `$formatNumber` (`Jsonata.FormatNumber`): the full XPath F&O
  DecimalFormat — grouping (regular/irregular), exponent notation, percent and
  per-mille scaling, the positive;negative sub-picture pair, a `properties`
  options object, and `D3080`–`D3093` picture validation.
- **`$string`** — ECMAScript-compatible number formatting (`1e21` → `"1e+21"`,
  `1e-7` → `"1e-7"`, `1e-6` → `"0.000001"`), 15-significant-digit rounding of
  non-integers (`22/7` → `"3.14285714285714"`), functions serialized as `""`, and
  the `prettify` argument (2-space indented JSON). The `&` concatenation operator
  shares the same number formatting.
- **Host integration** — `$eval`, and registering Elixir functions as callable
  `$fn` via `Jsonata.evaluate/3` bindings.
- **Tooling** — `credo --strict`, `dialyzer` (clean), 90%+ test coverage, and
  StreamData property tests, all enforced in CI.

### Not yet implemented

- Order-sensitive object key handling (`$keys`/`$spread`/`$each`).
- JavaScript-style **async** functions (out of scope for the synchronous engine).
