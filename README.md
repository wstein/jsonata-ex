# JSONata for Elixir

A native Elixir port of [JSONata](https://jsonata.org/), the JSON query and
transformation language. This is a clean-room reimplementation tracking the
reference implementation [`jsonata-js`](https://github.com/jsonata-js/jsonata)
v2.2.1, validated against its language-agnostic conformance suite (~97% of
specified cases pass; see the gaps below).

## Usage

```elixir
# Evaluate a string expression against data
Jsonata.evaluate("Account.Order.Product.(Price * Quantity) ~> $sum()", data)
#=> {:ok, 90.6}

# Compile once, reuse across many inputs
{:ok, expr} = Jsonata.compile("items[price > 10].name")
Jsonata.evaluate(expr, data)

# Or write a literal expression with the compile-time sigil (~J is a short alias)
import Jsonata, only: [sigil_JSONATA: 2]
Jsonata.evaluate(~JSONATA"$uppercase(name)", %{"name" => "bob"})
#=> {:ok, "BOB"}

# Extend the language: an Elixir function bound as a variable is a callable $fn
Jsonata.evaluate("$double(21)", :undefined, %{"double" => fn n -> n * 2 end})
#=> {:ok, 42}
```

Input is plain decoded JSON (string-keyed maps, lists, scalars, `nil`). A missing
result is `:undefined` (distinct from JSON `null`).

## Implemented

Paths, predicates, all operators, ranges, conditionals, blocks, variable binds,
array/object constructors, wildcards/descendants; ~50 built-in functions with
signature validation; lambdas with closures and self-recursion; higher-order
functions; regex matchers; order-by `^`, group-by `{`, the positional
tuple-stream operators focus `@` / index `#` (joins), the parent operator `%`,
and the transform `|…|` operator; `$eval` and host functions.
`$formatInteger`/`$parseInteger` integer picture strings (decimal/grouping,
`;o` ordinals, Roman numerals, letter sequences, and spelled-out words);
`$formatNumber` (DecimalFormat — grouping, exponents, percent/per-mille, the
positive;negative pattern pair, and an options object); and date/time
picture-string formatting **and parsing** (`$fromMillis`/`$now`/`$toMillis` —
the `[Y0001]-[M01]-[D01]` component grammar with names, ordinals, spelled-out
words, week numbers, and timezones).

## Not yet implemented

- Order-sensitive object key handling (`$keys`/`$spread`/`$each`), which needs
  an insertion-order-preserving object representation (see below).
- Minor picture-string edge cases: non-ASCII digit groups and integers ≥ 10⁴⁶
  spelled out as words.

## Differences from jsonata-js

These are deliberate, documented divergences from the reference implementation —
not bugs. Most expressions are unaffected; the cases below are where an Elixir
host and the JavaScript reference legitimately differ.

- **Object key order is preserved for constructed and decoded objects, not for
  plain-map input.** Objects built by an expression (`{…}`, group-by, `$merge`,
  `$spread`) and objects decoded with `Jsonata.decode/1` keep insertion order, so
  `$keys`/`$spread`/`$each`/`$string` behave like jsonata-js. But a plain Elixir
  map passed directly as `input` has no insertion order (Elixir maps don't retain
  it), so key order for those functions over raw input data follows map-internal
  order. Decode JSON input with `Jsonata.decode/1` if you need input key order.
  The public result is always plain Elixir maps (object equality is
  order-insensitive).
- **Numbers are arbitrary-precision, not IEEE-754 doubles.** jsonata-js performs
  all arithmetic in JavaScript doubles; this port keeps exact integers. So
  `$factorial(100)` returns the exact 158-digit integer here, where jsonata-js
  returns `9.33…e157`. Non-integer results still use floats and render with the
  same ECMAScript rules (`1e21` → `"1e+21"`, 15-significant-digit `$string`
  rounding). The divergence only shows for integer results beyond 2⁵³.
- **Regex uses Erlang's `:re` (PCRE), not V8.** Patterns valid in both behave
  identically, but engine-specific syntax, some named-group and flag handling,
  and a few edge constructs differ between PCRE and V8.
- **`~> | … |` transform matches by value, not reference.** jsonata-js mutates a
  clone of the matched nodes by reference; the immutable port rebuilds the tree,
  keying each match's update/delete by the matched node's *value*. Results are
  identical unless two structurally-equal sibling objects are selected
  positionally (e.g. `(a.b)[0]`) — then both equal nodes receive the update.

The whole upstream conformance suite is run as a CI gate
(`mix test --only conformance`); the current score is **~96.5%**, and the gaps
above account for most of the remainder.

## Development

```bash
mix deps.get
mix format --check-formatted
mix compile --warnings-as-errors
mix credo --strict
mix test --cover
mix dialyzer
mix docs
mix run bench/jsonata_bench.exs   # Benchee micro-benchmarks

# Cross-runtime comparison against jsonata-js (needs Node):
cd bench/cross_runtime && npm install && cd -
mix run bench/cross_runtime/compare.exs
```

On the maintainer's machine the cross-runtime comparison shows this port
evaluating common expression shapes roughly 2–11× faster than jsonata-js
(compiled-expression, like-for-like); treat the ratios as ballpark and
re-measure on your own hardware.

The conformance suite lives in the sibling `jsonata` submodule. Its loader,
`Jsonata.Conformance` (in `test/support`, so it is not shipped in the package),
enumerates every upstream case; integration tests that depend on it skip
gracefully when the submodule is not checked out.

## License

MIT.
