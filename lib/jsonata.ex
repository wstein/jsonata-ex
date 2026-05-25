defmodule Jsonata do
  @moduledoc """
  A native Elixir port of the [JSONata](https://jsonata.org/) query and
  transformation language.

  Evaluate an expression against data with `evaluate/3`, or `compile/1` it once
  (or write it as a `~JSONATA` sigil) and reuse the compiled form across many
  inputs.

  ## Examples

      iex> Jsonata.evaluate("Account.Order.Product.(Price * Quantity)",
      ...>   %{"Account" => %{"Order" => %{"Product" => %{"Price" => 10, "Quantity" => 3}}}})
      {:ok, 30}

      iex> import Jsonata, only: [sigil_JSONATA: 2]
      iex> Jsonata.evaluate(~JSONATA"a + b", %{"a" => 1, "b" => 2})
      {:ok, 3}

  """

  alias Jsonata.{Environment, Error, Evaluator, Expression, Functions, Parser}

  @typedoc "Variable bindings; a value that is an Elixir function becomes a callable `$fn`."
  @type bindings :: %{optional(String.t()) => term()}

  @doc """
  Compiles a JSONata `expression` so it can be evaluated against many inputs
  without re-parsing. Returns `{:ok, %Jsonata.Expression{}}` or `{:error, _}`.
  """
  @spec compile(binary()) :: {:ok, Expression.t()} | {:error, Error.t()}
  def compile(expression) when is_binary(expression) do
    with {:ok, ast} <- Parser.parse(expression) do
      {:ok, %Expression{ast: ast, source: expression}}
    end
  end

  @doc """
  Evaluates a JSONata `expression` (a string or a compiled `Jsonata.Expression`)
  against `input`, with optional `bindings` (names without the leading `$`).

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
  @spec evaluate(binary() | Expression.t(), term(), bindings()) ::
          {:ok, term()} | {:error, Error.t()}
  def evaluate(expression, input \\ :undefined, bindings \\ %{})

  def evaluate(%Expression{ast: ast}, input, bindings), do: run(ast, input, bindings)

  def evaluate(expression, input, bindings) when is_binary(expression) do
    with {:ok, ast} <- Parser.parse(expression), do: run(ast, input, bindings)
  end

  @doc ~S"""
  Compiles a literal JSONata expression at compile time.

  `~JSONATA"expr"` expands to a `Jsonata.Expression` parsed during compilation, so
  the expression is validated when the module compiles and never re-parsed at
  runtime. Interpolation is rejected (an injection guard); build dynamic
  expressions with `compile/1` instead. `~J` is a short alias.

      ~JSONATA"Account.Order[0].Price"
  """
  defmacro sigil_JSONATA(term, _modifiers), do: compile_literal(term)

  @doc "Short alias for `sigil_JSONATA/2` — `~J\"expr\"`."
  defmacro sigil_J(term, _modifiers), do: compile_literal(term)

  defp compile_literal({:<<>>, _meta, [string]}) when is_binary(string),
    do: compile_literal(string)

  defp compile_literal(string) when is_binary(string) do
    case Parser.parse(string) do
      {:ok, ast} -> Macro.escape(%Expression{ast: ast, source: string})
      {:error, error} -> raise error
    end
  end

  defp run(ast, input, bindings) do
    env =
      Enum.reduce(bindings, Functions.bind_all(Environment.root(input)), fn {name, value}, env ->
        Environment.bind(env, name, host_value(name, value))
      end)

    # ordered objects are an internal representation (ADR-3); the public contract
    # is plain Elixir maps, so collapse them at the output boundary
    {:ok, Jsonata.Object.to_plain(Evaluator.evaluate(ast, input, env))}
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
  Decodes a JSON `string` into a value suitable as `evaluate/3` input,
  **preserving object key order** (objects become `Jsonata.Object`, arrays become
  lists, `null` becomes `nil`).

  Use this instead of a plain-map decode when `$keys`/`$spread`/`$each`/`$string`
  over the input must follow JSON insertion order. Returns `{:ok, value}` or
  `{:error, reason}`.

      iex> {:ok, data} = Jsonata.decode(~s({"b": 1, "a": 2}))
      iex> Jsonata.evaluate("$keys($)", data)
      {:ok, ["b", "a"]}

  """
  @spec decode(binary()) :: {:ok, term()} | {:error, term()}
  defdelegate decode(string), to: Jsonata.Object, as: :from_json

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
