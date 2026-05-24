defmodule Jsonata.AST do
  @moduledoc """
  JSONata abstract syntax tree.

  Following the reference implementation (ADR-1: parser ≈ 1:1), AST nodes are
  tagged maps with an atom `:type` rather than one struct per node kind. This
  keeps the parser and its post-processing close to `parser.js` and lets the
  evaluator dispatch with multi-clause pattern matching (technique T4).

  Node kinds produced by `Jsonata.Parser`:

    * `%{type: :number | :string | :value, value: term}` — literals
    * `%{type: :name, value: String.t}` — a path step / field name
    * `%{type: :variable, value: String.t}` — `$name` (`""` is the context, `"$"` the root)
    * `%{type: :wildcard | :descendant}` — `*` and `**`
    * `%{type: :unary, value: "-", expression: node}` — unary minus
    * `%{type: :unary, value: "[", expressions: [node]}` — array constructor
    * `%{type: :unary, value: "{", lhs: [[key, value]]}` — object constructor
    * `%{type: :binary, value: op, lhs: node, rhs: node}` — binary operators
    * `%{type: :path, steps: [node]}` — a location path (produced by post-processing)
    * `%{type: :bind, lhs: node, rhs: node}` — `:=`
    * `%{type: :block, expressions: [node]}` — `( e1; e2 )`
    * `%{type: :condition, condition:, then:, else: (optional)}` — `? :` and `?:`
    * `%{type: :coalesce, lhs: node, rhs: node}` — `??`
    * `%{type: :function | :lambda, ...}` — parsed but evaluated in later phases

  Steps in a `:path` may carry a `:stages` list of `%{type: :filter, expr: node}`
  predicate stages, and flags such as `:keep_array` / `:cons_array`.
  """

  @type t :: %{:type => atom(), optional(atom()) => term()}
end
