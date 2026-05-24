defmodule Jsonata.ValueTest do
  use ExUnit.Case, async: true

  require Jsonata.Value
  alias Jsonata.{Sequence, Value}

  describe "nothing" do
    test "nothing/0 is the :undefined sentinel" do
      assert Value.nothing() == :undefined
    end

    test "nothing?/1 distinguishes nothing from null and other values" do
      assert Value.nothing?(:undefined)
      refute Value.nothing?(nil)
      refute Value.nothing?(0)
      refute Value.nothing?("")
    end

    test "is_nothing/1 works as a guard" do
      assert Value.is_nothing(:undefined)
      refute Value.is_nothing(nil)
    end
  end

  describe "deep_equal/2 scalars" do
    test "numbers compare by value across integer/float" do
      assert Value.deep_equal(1, 1.0)
      assert Value.deep_equal(2.5, 2.5)
      refute Value.deep_equal(1, 2)
    end

    test "strings, booleans, and null" do
      assert Value.deep_equal("a", "a")
      assert Value.deep_equal(true, true)
      assert Value.deep_equal(nil, nil)
      refute Value.deep_equal("a", "b")
      refute Value.deep_equal(1, true)
      refute Value.deep_equal(nil, false)
    end

    test "nothing equals only nothing" do
      assert Value.deep_equal(:undefined, :undefined)
      refute Value.deep_equal(:undefined, nil)
    end
  end

  describe "deep_equal/2 arrays" do
    test "equal by ordered elements" do
      assert Value.deep_equal([1, 2, 3], [1, 2, 3])
      refute Value.deep_equal([1, 2, 3], [3, 2, 1])
      refute Value.deep_equal([1, 2], [1, 2, 3])
    end

    test "sequences compare equal to equivalent lists" do
      assert Value.deep_equal(Sequence.from_value([1, 2]), [1, 2])
      assert Value.deep_equal(Sequence.from_value([1, 2]), Sequence.from_value([1, 2]))
    end

    test "nested structures" do
      assert Value.deep_equal([%{"a" => [1, 2]}], [%{"a" => [1, 2.0]}])
    end
  end

  describe "deep_equal/2 objects" do
    test "equal regardless of key order" do
      assert Value.deep_equal(%{"a" => 1, "b" => 2}, %{"b" => 2, "a" => 1})
    end

    test "differing keys or values are unequal" do
      refute Value.deep_equal(%{"a" => 1}, %{"a" => 1, "b" => 2})
      refute Value.deep_equal(%{"a" => 1}, %{"a" => 2})
      refute Value.deep_equal(%{"a" => 1}, %{"b" => 1})
    end

    test "an object is not equal to an array" do
      refute Value.deep_equal(%{}, [])
    end
  end
end
