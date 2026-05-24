defmodule Jsonata.Function do
  @moduledoc """
  A callable JSONata function value — a built-in, a user lambda, or a closure
  wrapping one of those when passed as an argument to a higher-order function.

  Exactly one of the following shapes is populated:

    * **built-in / closure** — `impl` takes the validated argument list and returns
      a value.
    * **lambda** — `params` (argument names), `body` (AST), and the captured
      `env`/`input` of its definition site; applied by binding params to args in a
      child of `env` and evaluating `body`.

  `arity` is the declared argument count, used by higher-order functions to decide
  how many of `(value, index, array)` to pass. `signature` (when present) validates
  and fixes up arguments before application.
  """

  @enforce_keys [:name]
  defstruct [:name, :impl, :signature, :params, :body, :env, :input, :self_name, :regex, arity: 0]

  @type t :: %__MODULE__{
          name: String.t(),
          impl: ([term()] -> term()) | nil,
          signature: Jsonata.Signature.t() | nil,
          params: [String.t()] | nil,
          body: Jsonata.AST.t() | nil,
          env: term() | nil,
          input: term() | nil,
          self_name: String.t() | nil,
          regex: Regex.t() | nil,
          arity: non_neg_integer()
        }
end
