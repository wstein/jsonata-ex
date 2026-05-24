defmodule Jsonata do
  @moduledoc """
  A native Elixir port of the [JSONata](https://jsonata.org/) query and
  transformation language.

  This module is the intended public entry point. The language is being
  implemented in phases; the parser and evaluator are not yet wired up, so no
  `evaluate/2` is exposed. The building blocks available today are
  `Jsonata.Tokenizer`, `Jsonata.Sequence`, `Jsonata.AST`, and `Jsonata.Value`.
  """

  alias Jsonata.{Environment, Error, Evaluator, Parser}

  @doc """
  Evaluates a JSONata `expression` against `input`, with optional variable
  `bindings` (a map of names to values, without the leading `$`).

  Returns `{:ok, result}` where a missing result is `:undefined`, or
  `{:error, %Jsonata.Error{}}` for a parse or evaluation error.

  ## Examples

      iex> Jsonata.evaluate("a + b", %{"a" => 1, "b" => 2})
      {:ok, 3}

      iex> Jsonata.evaluate("foo", %{"bar" => 1})
      {:ok, :undefined}

  """
  @spec evaluate(binary(), term(), %{optional(String.t()) => term()}) ::
          {:ok, term()} | {:error, Error.t()}
  def evaluate(expression, input \\ :undefined, bindings \\ %{}) when is_binary(expression) do
    with {:ok, ast} <- Parser.parse(expression) do
      env =
        Enum.reduce(bindings, Environment.root(input), fn {name, value}, env ->
          Environment.bind(env, name, value)
        end)

      {:ok, Evaluator.evaluate(ast, input, env)}
    end
  rescue
    error in Error -> {:error, error}
  end

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
