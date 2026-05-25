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

  ## Options

  For untrusted expressions/input, `opts` can bound evaluation by running it in
  an isolated process:

    * `:max_heap_size` — kill the evaluation if its heap exceeds this many words
    * `:timeout` — kill it if it runs longer than this many milliseconds

  Either limit being breached returns `{:error, %Jsonata.Error{code: "U1001"}}`.
  When neither is set, evaluation runs inline (no process overhead). Host
  functions and the input are copied to the isolated process, so a host function
  that relies on shared process state will not see it there.

  ## Examples

      iex> Jsonata.evaluate("a + b", %{"a" => 1, "b" => 2})
      {:ok, 3}

      iex> Jsonata.evaluate("foo", %{"bar" => 1})
      {:ok, :undefined}

      iex> Jsonata.evaluate("$double(21)", :undefined, %{"double" => fn n -> n * 2 end})
      {:ok, 42}

      iex> match?({:error, %Jsonata.Error{code: "U1001"}},
      ...>   Jsonata.evaluate("[1..1e7]", :undefined, %{}, max_heap_size: 100_000))
      true

  """
  @spec evaluate(binary() | Expression.t(), term(), bindings(), keyword()) ::
          {:ok, term()} | {:error, Error.t()}
  def evaluate(expression, input \\ :undefined, bindings \\ %{}, opts \\ [])

  def evaluate(%Expression{ast: ast}, input, bindings, opts), do: run(ast, input, bindings, opts)

  def evaluate(expression, input, bindings, opts) when is_binary(expression) do
    with {:ok, ast} <- Parser.parse(expression), do: run(ast, input, bindings, opts)
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

  defp run(ast, input, bindings, opts) do
    case Keyword.take(opts, [:max_heap_size, :timeout]) do
      [] -> run_inline(ast, input, bindings)
      limits -> run_guarded(ast, input, bindings, limits)
    end
  end

  defp run_inline(ast, input, bindings) do
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

  # Runs evaluation in an isolated, optionally heap-capped/time-limited process
  # so untrusted input cannot exhaust the caller's heap or hang it.
  defp run_guarded(ast, input, bindings, limits) do
    parent = self()
    timeout = Keyword.get(limits, :timeout, :infinity)
    max_heap = Keyword.get(limits, :max_heap_size)

    {pid, ref} =
      spawn_monitor(fn ->
        if max_heap do
          Process.flag(:max_heap_size, %{size: max_heap, kill: true, error_logger: false})
        end

        send(parent, {:jsonata_result, run_inline(ast, input, bindings)})
      end)

    receive do
      {:jsonata_result, result} ->
        Process.demonitor(ref, [:flush])
        result

      {:DOWN, ^ref, :process, _pid, _reason} ->
        {:error, Error.new("U1001", value: "max_heap_size")}
    after
      timeout ->
        Process.exit(pid, :kill)
        {:error, Error.new("U1001", value: "timeout")}
    end
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
