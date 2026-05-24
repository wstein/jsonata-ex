# JSONata for Elixir

A native Elixir port of [JSONata](https://jsonata.org/), the JSON query and
transformation language. This is a clean-room reimplementation tracking the
reference implementation [`jsonata-js`](https://github.com/jsonata-js/jsonata)
v2.2.1, validated against its language-agnostic conformance suite (~87% of
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
functions; regex matchers; order-by `^`, group-by `{`, and the positional
tuple-stream operators focus `@` / index `#` (joins); `$eval` and host functions.
`$formatInteger`/`$parseInteger` integer picture strings (decimal/grouping,
`;o` ordinals, Roman numerals, letter sequences, and spelled-out words);
`$formatNumber` (DecimalFormat — grouping, exponents, percent/per-mille, the
positive;negative pattern pair, and an options object); and date/time
picture-string formatting (`$fromMillis`/`$now` — the `[Y0001]-[M01]-[D01]`
component grammar with names, ordinals, week numbers, and timezones).

## Not yet implemented

- Date/time picture-string **parsing** (`$toMillis` with a picture). Date/time
  *formatting* (`$fromMillis`/`$now`) and integer/number picture strings are
  done, except for non-ASCII digit groups and numbers ≥ 10⁴⁶.
- The **parent operator** `%`, the **transform** `|…|` operator, and
  order-sensitive object key handling (`$keys`/`$spread`/`$each`).

## Development

```bash
mix deps.get
mix format --check-formatted
mix compile --warnings-as-errors
mix credo --strict
mix test --cover
mix dialyzer
mix docs
```

The conformance suite lives in the sibling `jsonata` submodule. When present,
`Jsonata.Conformance.load/0` enumerates every upstream case; integration tests
that depend on it skip gracefully when the submodule is not checked out.

## License

MIT.
