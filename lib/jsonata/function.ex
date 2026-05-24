defmodule Jsonata.Function do
  @moduledoc """
  A callable JSONata function value: a built-in (or, in later phases, a lambda).

  `impl` takes the validated argument list and returns a JSONata value. `signature`
  is the parsed `Jsonata.Signature` used to validate and fix up arguments before
  the implementation runs (`nil` for unsignatured functions).
  """

  @enforce_keys [:name, :impl]
  defstruct [:name, :impl, :signature]

  @type t :: %__MODULE__{
          name: String.t(),
          impl: ([term()] -> term()),
          signature: Jsonata.Signature.t() | nil
        }
end
