defmodule Jsonata.Object do
  @moduledoc """
  An insertion-order-preserving JSONata object (ADR-3).

  JSONata objects must preserve key insertion order for `$keys`, `$spread`,
  `$each`, and `$string`. Elixir maps do not, so constructed and order-decoded
  objects use this struct (an ordered key list + a map for O(1) value access).

  The **read** functions (`object?/1`, `get/2`, `keys/1`, `pairs/1`, `has_key?/2`,
  `size/1`) also accept a plain map, so call sites can treat both uniformly: a
  user-supplied plain map simply has no defined order (it iterates in map order),
  while a constructed/decoded `Jsonata.Object` carries insertion order. Values are
  converted back to plain maps at the public output boundary via `to_plain/1`.
  """

  # `id` is an optional, JSONata-invisible identity tag (not a logical key): the
  # transform operator stamps it so it can update the *specific* matched node by
  # position rather than by value. It is ignored by every read function and by
  # equality, and dropped by `to_plain/1`.
  @enforce_keys [:keys, :map]
  defstruct keys: [], map: %{}, id: nil

  @type t :: %__MODULE__{
          keys: [String.t()],
          map: %{optional(String.t()) => term()},
          id: term()
        }

  @doc "An empty ordered object."
  @spec new() :: t()
  def new, do: %__MODULE__{keys: [], map: %{}}

  @doc "Builds an ordered object from a list of `{key, value}` pairs (first wins on order)."
  @spec new([{String.t(), term()}]) :: t()
  def new(pairs) when is_list(pairs),
    do: Enum.reduce(pairs, new(), fn {key, value}, object -> put(object, key, value) end)

  @doc "Adds/replaces `key`; a new key is appended, an existing key keeps its position."
  @spec put(t(), String.t(), term()) :: t()
  def put(%__MODULE__{keys: keys, map: map} = object, key, value) do
    keys = if Map.has_key?(map, key), do: keys, else: keys ++ [key]
    %{object | keys: keys, map: Map.put(map, key, value)}
  end

  @doc "Removes `key` (a no-op if absent)."
  @spec delete(t(), String.t()) :: t()
  def delete(%__MODULE__{keys: keys, map: map} = object, key),
    do: %{object | keys: List.delete(keys, key), map: Map.delete(map, key)}

  @doc "Merges `b` into `a`, appending `b`'s new keys in order."
  @spec merge(t(), t()) :: t()
  def merge(%__MODULE__{} = a, %__MODULE__{} = b),
    do: Enum.reduce(pairs(b), a, fn {key, value}, acc -> put(acc, key, value) end)

  # --- reads (accept an Object or a plain map) ------------------------------

  @doc "Whether `value` is a JSONata object (an `Object` struct or a plain map)."
  @spec object?(term()) :: boolean()
  def object?(%__MODULE__{}), do: true
  def object?(value) when is_map(value), do: not is_struct(value)
  def object?(_value), do: false

  @doc "The value for `key`, or `default`."
  @spec get(t() | map(), String.t(), term()) :: term()
  def get(object, key, default \\ nil)
  def get(%__MODULE__{map: map}, key, default), do: Map.get(map, key, default)
  def get(map, key, default) when is_map(map), do: Map.get(map, key, default)

  @doc "The keys, in insertion order for an `Object` (map order for a plain map)."
  @spec keys(t() | map()) :: [String.t()]
  def keys(%__MODULE__{keys: keys}), do: keys
  def keys(map) when is_map(map), do: Map.keys(map)

  @doc "The `{key, value}` pairs, ordered as `keys/1`."
  @spec pairs(t() | map()) :: [{String.t(), term()}]
  def pairs(%__MODULE__{keys: keys, map: map}), do: Enum.map(keys, &{&1, Map.fetch!(map, &1)})
  def pairs(map) when is_map(map), do: Map.to_list(map)

  @doc "Whether `key` is present."
  @spec has_key?(t() | map(), String.t()) :: boolean()
  def has_key?(%__MODULE__{map: map}, key), do: Map.has_key?(map, key)
  def has_key?(map, key) when is_map(map), do: Map.has_key?(map, key)

  @doc "The number of keys."
  @spec size(t() | map()) :: non_neg_integer()
  def size(%__MODULE__{keys: keys}), do: length(keys)
  def size(map) when is_map(map), do: map_size(map)

  # --- boundary conversion --------------------------------------------------

  @doc """
  Recursively converts `Object` structs to plain maps (for the public output
  boundary, where the contract is plain Elixir maps). Order is lost — which is
  fine, since map equality is order-insensitive.
  """
  @spec to_plain(term()) :: term()
  def to_plain(%__MODULE__{} = object),
    do: Map.new(object.keys, fn key -> {key, to_plain(Map.fetch!(object.map, key))} end)

  def to_plain(value) when is_map(value) and not is_struct(value),
    do: Map.new(value, fn {key, val} -> {key, to_plain(val)} end)

  def to_plain(value) when is_list(value), do: Enum.map(value, &to_plain/1)
  def to_plain(value), do: value

  @decoders %{
    object_push: &__MODULE__.decode_push/3,
    object_finish: &__MODULE__.decode_finish/2,
    null: nil
  }

  @doc """
  Decodes a JSON `string`, preserving object key order as `Jsonata.Object`s
  (arrays → lists, `null` → `nil`). Returns `{:ok, value}` or `{:error, reason}`.
  """
  @spec from_json(String.t()) :: {:ok, term()} | {:error, term()}
  def from_json(string) when is_binary(string) do
    case :json.decode(string, :ok, @decoders) do
      {value, :ok, ""} -> {:ok, value}
      {_value, _acc, rest} -> {:error, {:trailing, rest}}
    end
  rescue
    error -> {:error, error}
  end

  @doc false
  def decode_push(key, value, acc), do: [{key, value} | acc]

  @doc false
  def decode_finish(acc, old_acc), do: {new(Enum.reverse(acc)), old_acc}
end
