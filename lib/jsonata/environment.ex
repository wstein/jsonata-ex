defmodule Jsonata.Environment do
  @moduledoc """
  Lexical environment for evaluation: an immutable frame of variable bindings
  with a parent pointer (ADR: immutable scope, no mutation).

  Variable lookups walk the parent chain. Binding returns a new environment, so
  the evaluator threads the environment through a block's expressions to make
  `:=` visible to later expressions in the same scope.
  """

  alias __MODULE__

  @enforce_keys [:bindings]
  defstruct bindings: %{}, parent: nil

  @type t :: %Environment{bindings: %{optional(String.t()) => term()}, parent: t() | nil}

  @doc "Creates a root environment with `root_input` bound to `$`."
  @spec root(term()) :: t()
  def root(root_input), do: %Environment{bindings: %{"$" => root_input}, parent: nil}

  @doc "Creates a child frame nested in `parent`."
  @spec child(t()) :: t()
  def child(parent), do: %Environment{bindings: %{}, parent: parent}

  @doc "Returns a new environment with `name` bound to `value`."
  @spec bind(t(), String.t(), term()) :: t()
  def bind(%Environment{} = env, name, value),
    do: %{env | bindings: Map.put(env.bindings, name, value)}

  @doc "Looks up `name`, walking the parent chain. Returns `:undefined` if unbound."
  @spec lookup(t(), String.t()) :: term()
  def lookup(%Environment{bindings: bindings, parent: parent}, name) do
    case Map.fetch(bindings, name) do
      {:ok, value} -> value
      :error -> if parent, do: lookup(parent, name), else: :undefined
    end
  end
end
