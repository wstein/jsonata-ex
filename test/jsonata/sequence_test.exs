defmodule Jsonata.SequenceTest do
  use ExUnit.Case, async: true

  alias Jsonata.{Error, Sequence}

  describe "construction" do
    test "empty/1, singleton/2, from_value/2" do
      assert Sequence.to_value(Sequence.empty()) == []
      assert Sequence.to_value(Sequence.singleton(7)) == [7]
      assert Sequence.to_value(Sequence.from_value([1, 2, 3])) == [1, 2, 3]
    end

    test "opts set struct flags" do
      assert %Sequence{keep_singleton: true} = Sequence.singleton(1, keep_singleton: true)
      assert %Sequence{cons: true} = Sequence.from_value([1], cons: true)
    end
  end

  describe "sequence?/1" do
    test "plain sequences are sequences" do
      assert Sequence.sequence?(Sequence.empty())
      assert Sequence.sequence?(Sequence.from_value([1]))
    end

    test "cons arrays and tuple streams are not sequences" do
      refute Sequence.sequence?(Sequence.from_value([1], cons: true))
      refute Sequence.sequence?(Sequence.empty(tuple_stream: true))
    end

    test "non-sequences are not sequences" do
      refute Sequence.sequence?([1, 2])
      refute Sequence.sequence?(42)
      refute Sequence.sequence?(%{})
    end
  end

  describe "append_step/2 flatten rule" do
    test "scalars are appended atomically" do
      seq = Sequence.empty() |> Sequence.append_step(1) |> Sequence.append_step(2)
      assert Sequence.to_value(seq) == [1, 2]
    end

    test "plain data lists flatten" do
      seq = Sequence.append_step(Sequence.empty(), [1, 2, 3])
      assert Sequence.to_value(seq) == [1, 2, 3]
    end

    test "genuine sequences flatten" do
      seq = Sequence.append_step(Sequence.singleton(0), Sequence.from_value([1, 2]))
      assert Sequence.to_value(seq) == [0, 1, 2]
    end

    test "objects are appended atomically" do
      seq = Sequence.append_step(Sequence.empty(), %{"a" => 1})
      assert Sequence.to_value(seq) == [%{"a" => 1}]
    end

    test "cons arrays stay atomic (a single element)" do
      cons = Sequence.from_value([1, 2], cons: true)
      seq = Sequence.append_step(Sequence.empty(), cons)
      assert Sequence.to_value(seq) == [cons]
    end
  end

  describe "collapse/2" do
    test "empty collapses to :undefined" do
      assert Sequence.collapse(Sequence.empty(), false) == :undefined
    end

    test "a singleton collapses to its element" do
      assert Sequence.collapse(Sequence.singleton(42), false) == 42
    end

    test "keep_singleton retains a one-element array" do
      assert Sequence.collapse(Sequence.singleton(42, keep_singleton: true), false) == [42]
    end

    test "the keep_array? argument forces array retention" do
      assert Sequence.collapse(Sequence.singleton(42), true) == [42]
    end

    test "multiple elements collapse to the array value" do
      assert Sequence.collapse(Sequence.from_value([1, 2, 3]), false) == [1, 2, 3]
    end

    test "tuple streams are returned unchanged" do
      seq = Sequence.empty(tuple_stream: true)
      assert Sequence.collapse(seq, false) == seq
    end
  end

  describe "lazy backend and Enumerable (T6)" do
    test "a lazy sequence streams through Enum/Stream" do
      seq = Sequence.lazy(Stream.map(1..3, &(&1 * 10)))
      assert Enum.to_list(seq) == [10, 20, 30]
      assert Enum.map(seq, & &1) == [10, 20, 30]
      assert Enum.member?(seq, 20)
      assert Enum.at(seq, 1) == 20
    end

    test "an eager sequence supports member?, count, and slice directly" do
      seq = Sequence.from_value([1, 2, 3])
      assert Enum.member?(seq, 2)
      refute Enum.member?(seq, 9)
      assert Enum.count(seq) == 3
      assert Enum.at(seq, 2) == 3
      assert Enum.slice(seq, 1, 2) == [2, 3]
    end

    test "to_value materializes a lazy sequence" do
      seq = Sequence.lazy(Stream.take(Stream.iterate(1, &(&1 + 1)), 4))
      assert Sequence.to_value(seq) == [1, 2, 3, 4]
    end

    test "collapse decides empty/singleton on a lazy sequence without forcing the tail" do
      # An infinite stream that is empty or single after `Enum.take(_, 2)` is cheap;
      # only multi-element results call `to_value`, so use finite streams there.
      infinite = Stream.iterate(0, fn _ -> raise "tail forced" end)
      assert Sequence.collapse(Sequence.lazy(Stream.take(infinite, 1)), false) == 0
      assert Sequence.collapse(Sequence.lazy(Stream.map([], & &1)), false) == :undefined
      assert Sequence.collapse(Sequence.lazy(Stream.map([1, 2], & &1)), false) == [1, 2]
    end

    test "Enum.count is exact for eager and computed for lazy" do
      assert Enum.count(Sequence.from_value([1, 2, 3])) == 3
      assert Enum.count(Sequence.lazy(Stream.map([1, 2], & &1))) == 2
    end

    test "append_step flattens into a lazy accumulator" do
      seq =
        Sequence.lazy(Stream.map([1], & &1))
        |> Sequence.append_step([2, 3])
        |> Sequence.append_step(4)

      assert Sequence.to_value(seq) == [1, 2, 3, 4]
    end
  end

  describe "max_size guardrail" do
    test "materializing past max_size raises D2015" do
      seq = Sequence.lazy(Stream.cycle([1]), max_size: 3)

      assert_raise Error, "The maximum sequence length of 3 was exceeded.", fn ->
        Sequence.materialize(seq)
      end
    end

    test "materializing within max_size succeeds" do
      seq = Sequence.lazy(Stream.map([1, 2], & &1), max_size: 5)
      assert Sequence.to_value(seq) == [1, 2]
    end

    test "an eager sequence is returned unchanged by materialize" do
      seq = Sequence.from_value([1, 2])
      assert Sequence.materialize(seq) == seq
    end
  end

  describe "Enumerable fallbacks for lazy:false with non-list items" do
    test "member? delegates to Enumerable when items is a non-list enumerable" do
      # Use a MapSet whose Enumerable.member? returns {:ok, bool} so the fallback
      # clause (lazy:false, non-list) is exercised without the error-module leak.
      seq = %Jsonata.Sequence{items: MapSet.new([1, 2, 3]), lazy: false}
      assert Enum.member?(seq, 2)
      refute Enum.member?(seq, 9)
    end

    test "count delegates to Enumerable when items is a non-list enumerable" do
      seq = %Jsonata.Sequence{items: MapSet.new([1, 2, 3]), lazy: false}
      assert Enum.count(seq) == 3
    end
  end
end
