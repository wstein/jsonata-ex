defmodule Jsonata do
  @moduledoc """
  A native Elixir port of the [JSONata](https://jsonata.org/) query and
  transformation language.

  This module is the intended public entry point. The language is being
  implemented in phases; the parser and evaluator are not yet wired up, so no
  `evaluate/2` is exposed. The building blocks available today are
  `Jsonata.Tokenizer`, `Jsonata.Sequence`, `Jsonata.AST`, and `Jsonata.Value`.
  """

  @doc """
  Returns the library version.

  ## Examples

      iex> Jsonata.version() =~ ~r/^\\d+\\.\\d+\\.\\d+/
      true

  """
  @spec version() :: String.t()
  def version do
    :jsonata
    |> Application.spec(:vsn)
    |> to_string()
  end
end
