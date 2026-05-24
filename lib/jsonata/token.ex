defmodule Jsonata.Token do
  @moduledoc """
  A lexical token produced by `Jsonata.Tokenizer`.

  `position` is the source offset immediately after the token (the convention
  used by the reference implementation, which the parser relies on for error
  reporting). Token shapes by `type`:

    * `:operator` — `value` is the operator string (e.g. `"+"`, `":="`, `"~>"`)
    * `:string` — `value` is the decoded string
    * `:number` — `value` is an integer or float
    * `:name` — `value` is the (possibly backtick-quoted) identifier
    * `:variable` — `value` is the variable name without the leading `$`
    * `:value` — `value` is `true`, `false`, or `nil` (JSON `null`)
    * `:regex` — `value` is `%{pattern: String.t(), flags: String.t()}`
  """

  @type type :: :operator | :string | :number | :name | :variable | :value | :regex

  @type t :: %__MODULE__{
          type: type(),
          value: term(),
          position: non_neg_integer()
        }

  @enforce_keys [:type, :value, :position]
  defstruct [:type, :value, :position]
end
