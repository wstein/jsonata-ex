defmodule Jsonata.Sequence do
  @moduledoc """
  The JSONata sequence — the streaming accumulator produced by path navigation
  and higher-order functions. It is distinct from a JSON array value (those are
  plain Elixir lists).

  This is the `Jsonata.Sequence` contract from Appendix A of the implementation
  plan. The backing collection (`:items`) may be an eager list or a lazy
  `Stream`, and `Jsonata.Sequence` implements `Enumerable` by delegating to it,
  so callers consume sequences only through `Enum`/`Stream` or the functions
  here — never by reaching into `:items` (technique T6, enabling ADR-7).

  Flags mirror the flag-tagged arrays of the reference implementation:

    * `cons` — an atomic value-array (from the `[...]` constructor) that must not
      flatten during path navigation
    * `keep_singleton` — a one-element sequence must not collapse to a scalar
    * `outer_wrapper` — the whole input array is a single item
    * `tuple_stream` — elements are tuple-binding maps; such sequences never
      collapse
  """

  alias __MODULE__
  alias Jsonata.Error

  @enforce_keys [:items]
  defstruct items: [],
            lazy: false,
            keep_singleton: false,
            cons: false,
            outer_wrapper: false,
            tuple_stream: false,
            max_size: :infinity

  @type t :: %Sequence{
          items: Enumerable.t(),
          lazy: boolean(),
          keep_singleton: boolean(),
          cons: boolean(),
          outer_wrapper: boolean(),
          tuple_stream: boolean(),
          max_size: non_neg_integer() | :infinity
        }

  @doc "An empty sequence. `opts` set struct flags (e.g. `keep_singleton: true`)."
  @spec empty(keyword()) :: t()
  def empty(opts \\ []), do: struct!(%Sequence{items: []}, opts)

  @doc "A sequence holding a single `value`."
  @spec singleton(term(), keyword()) :: t()
  def singleton(value, opts \\ []), do: struct!(%Sequence{items: [value]}, opts)

  @doc "Wraps a JSON-data array as a (flattening) sequence."
  @spec from_value([term()], keyword()) :: t()
  def from_value(list, opts \\ []) when is_list(list), do: struct!(%Sequence{items: list}, opts)

  @doc "A lazy sequence whose `items` is a `Stream`; length-dependent operations force it."
  @spec lazy(Enumerable.t(), keyword()) :: t()
  def lazy(stream, opts \\ []), do: struct!(%Sequence{items: stream, lazy: true}, opts)

  @doc """
  Returns `true` if `value` is a genuine sequence.

  `cons` arrays and tuple streams are *not* sequences (they are atomic / specially
  shaped), mirroring `utils.isSequence`.
  """
  @spec sequence?(term()) :: boolean()
  def sequence?(%Sequence{cons: false, tuple_stream: false}), do: true
  def sequence?(_value), do: false

  @doc """
  Appends one path-step result to `acc`, applying the flatten rule.

  Genuine sequences and plain JSON-data lists are flattened into `acc`; scalars,
  objects, and `cons` arrays are appended as a single element. Because Elixir
  lists cannot be flag-tagged, the caller must represent constructor (`[...]`)
  arrays as `%Sequence{cons: true}` so they stay atomic here (Appendix A open
  decision on `cons` modeling).
  """
  @spec append_step(t(), term()) :: t()
  def append_step(%Sequence{} = acc, item) do
    cond do
      sequence?(item) -> concat_items(acc, item.items)
      is_list(item) -> concat_items(acc, item)
      true -> concat_items(acc, [item])
    end
  end

  @doc """
  Collapses a sequence on path exit: empty becomes `:undefined`, a single element
  becomes that element (unless `keep_singleton`), otherwise the array value.

  Tuple streams are returned unchanged. Only the first two elements are forced,
  so this stays cheap for lazy sequences.
  """
  @spec collapse(t(), boolean()) :: term()
  def collapse(%Sequence{tuple_stream: true} = seq, _keep_array?), do: seq

  def collapse(%Sequence{} = seq, keep_array?) do
    seq = %{seq | keep_singleton: seq.keep_singleton or keep_array?}

    case Enum.take(seq, 2) do
      [] -> :undefined
      [one] -> if seq.keep_singleton, do: to_value(seq), else: one
      _more -> to_value(seq)
    end
  end

  @doc "Materializes the sequence and returns its elements as a plain JSON array."
  @spec to_value(t()) :: [term()]
  def to_value(%Sequence{} = seq), do: materialize(seq).items

  @doc """
  Forces a lazy sequence to an eager list, enforcing the `max_size` guardrail
  (raises `Jsonata.Error` D2015 when exceeded). Eager sequences are returned
  unchanged.
  """
  @spec materialize(t()) :: t()
  def materialize(%Sequence{lazy: false} = seq), do: seq

  def materialize(%Sequence{lazy: true, max_size: :infinity} = seq),
    do: %{seq | items: Enum.to_list(seq.items), lazy: false}

  def materialize(%Sequence{lazy: true, max_size: max} = seq) do
    taken = Enum.take(seq.items, max + 1)

    if length(taken) > max do
      raise Error, code: "D2015", value: max
    end

    %{seq | items: taken, lazy: false}
  end

  defp concat_items(%Sequence{lazy: true} = acc, more),
    do: %{acc | items: Stream.concat(acc.items, more)}

  defp concat_items(%Sequence{lazy: false} = acc, more),
    do: %{acc | items: Enum.concat(acc.items, more)}

  defimpl Enumerable do
    def reduce(%{items: items}, acc, fun), do: Enumerable.reduce(items, acc, fun)

    def member?(%{lazy: false, items: items}, value) when is_list(items),
      do: {:ok, :lists.member(value, items)}

    def member?(%{lazy: false, items: items}, value), do: Enumerable.member?(items, value)
    def member?(%{lazy: true}, _value), do: {:error, __MODULE__}

    def count(%{lazy: false, items: items}) when is_list(items), do: {:ok, length(items)}
    def count(%{lazy: false, items: items}), do: Enumerable.count(items)
    def count(%{lazy: true}), do: {:error, __MODULE__}

    # Reduce-based slicing keeps both backends correct; the slicing function from
    # the inner collection would close over the wrong enumerable if delegated.
    def slice(_sequence), do: {:error, __MODULE__}
  end
end
