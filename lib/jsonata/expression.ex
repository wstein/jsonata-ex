defmodule Jsonata.Expression do
  @moduledoc """
  A compiled JSONata expression: the parsed AST plus its source.

  Produced by `Jsonata.compile/1` or the `~J` sigil, and passed to
  `Jsonata.evaluate/3` to skip re-parsing when an expression is evaluated against
  many inputs.
  """

  @enforce_keys [:ast, :source]
  defstruct [:ast, :source]

  @type t :: %__MODULE__{ast: Jsonata.AST.t(), source: String.t()}
end
