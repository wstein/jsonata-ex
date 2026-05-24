defmodule Jsonata do
  @moduledoc """
  A native Elixir port of the [JSONata](https://jsonata.org/) query and
  transformation language.

  This module is the intended public entry point. The language is being
  implemented in phases; the parser and evaluator are not yet wired up, so no
  `evaluate/2` is exposed. The building blocks available today are
  `Jsonata.Tokenizer`, `Jsonata.Sequence`, `Jsonata.AST`, and `Jsonata.Value`.
  """

  alias Jsonata.{Environment, Error, Evaluator, Functions, Parser}

  @doc """
  Evaluates a JSONata `expression` against `input`, with optional `bindings`
  (a map of names to values, without the leading `$`).

  A binding whose value is an Elixir function is registered as a callable
  JSONata function — host code can extend the language this way (`$myFn(...)`).

  Returns `{:ok, result}` where a missing result is `:undefined`, or
  `{:error, %Jsonata.Error{}}` for a parse or evaluation error.

  ## Examples

      iex> Jsonata.evaluate("a + b", %{"a" => 1, "b" => 2})
      {:ok, 3}

      iex> Jsonata.evaluate("foo", %{"bar" => 1})
      {:ok, :undefined}

      iex> Jsonata.evaluate("$double(21)", :undefined, %{"double" => fn n -> n * 2 end})
      {:ok, 42}

  """
  @spec evaluate(binary(), term(), %{optional(String.t()) => term()}) ::
          {:ok, term()} | {:error, Error.t()}
  def evaluate(expression, input \\ :undefined, bindings \\ %{}) when is_binary(expression) do
    with {:ok, ast} <- Parser.parse(expression) do
      env =
        bindings
        |> Enum.reduce(Functions.bind_all(Environment.root(input)), fn {name, value}, env ->
          Environment.bind(env, name, host_value(name, value))
        end)

      {:ok, Evaluator.evaluate(ast, input, env)}
    end
  rescue
    error in Error -> {:error, error}
  end

  # An Elixir function bound as a variable becomes a callable JSONata function.
  defp host_value(name, fun) when is_function(fun) do
    {:arity, arity} = Function.info(fun, :arity)
    %Jsonata.Function{name: name, arity: arity, impl: &apply(fun, &1)}
  end

  defp host_value(_name, value), do: value

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
