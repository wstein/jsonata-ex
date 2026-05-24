defmodule Jsonata.Value do
  @moduledoc """
  The JSONata value model.

  JSONata distinguishes *nothing* — the absence of a value, produced for example
  when a path matches no data — from JSON `null`. Per ADR-8, *nothing* is the
  atom `:undefined` and JSON null is `nil`. The `is_nothing/1` guard and
  `nothing?/1` predicate are the supported way to test for it.

  `deep_equal/2` implements JSONata value equality (a port of `utils.isDeepEqual`):
  sequences and arrays compare by ordered elements, objects by key set and
  values, and scalars by value (so `1` and `1.0` are equal).
  """

  alias Jsonata.Sequence

  @nothing :undefined

  @typedoc "The JSONata 'nothing' value — distinct from JSON null (`nil`)."
  @type nothing :: :undefined

  @typedoc "Any JSONata runtime value."
  @type t :: nothing() | nil | boolean() | number() | binary() | list() | map()

  @doc "Guard that is true for the JSONata *nothing* value."
  defguard is_nothing(value) when value == :undefined

  @doc "The *nothing* sentinel value."
  @spec nothing() :: nothing()
  def nothing, do: @nothing

  @doc "Returns `true` if `value` is JSONata *nothing*."
  @spec nothing?(term()) :: boolean()
  def nothing?(value), do: value == @nothing

  @doc """
  Compares two JSONata values for deep equality.

  Arrays and sequences are equal when they have the same elements in the same
  order; objects when they have the same keys and equal values; scalars by
  value. `:undefined` equals only `:undefined`.
  """
  @spec deep_equal(term(), term()) :: boolean()
  def deep_equal(left, right) do
    cond do
      enumerable?(left) and enumerable?(right) ->
        list_equal(Enum.to_list(left), Enum.to_list(right))

      object?(left) and object?(right) ->
        map_equal(left, right)

      true ->
        scalar_equal(left, right)
    end
  end

  defp enumerable?(value), do: is_list(value) or is_struct(value, Sequence)

  defp object?(value), do: is_map(value) and not is_struct(value)

  defp scalar_equal(left, right) when is_number(left) and is_number(right), do: left == right
  defp scalar_equal(left, right), do: left === right

  defp list_equal(left, right) when length(left) == length(right) do
    left |> Enum.zip(right) |> Enum.all?(fn {l, r} -> deep_equal(l, r) end)
  end

  defp list_equal(_left, _right), do: false

  defp map_equal(left, right) do
    Map.keys(left) |> Enum.sort() == Map.keys(right) |> Enum.sort() and
      Enum.all?(left, fn {key, value} -> deep_equal(value, Map.get(right, key)) end)
  end
end
