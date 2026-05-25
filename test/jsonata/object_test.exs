defmodule Jsonata.ObjectTest do
  use ExUnit.Case, async: true

  alias Jsonata.Object

  describe "construction and order" do
    test "new/1 preserves insertion order; put keeps an existing key's position" do
      object = Object.new([{"b", 1}, {"a", 2}, {"c", 3}])
      assert Object.keys(object) == ["b", "a", "c"]
      assert Object.keys(Object.put(object, "a", 99)) == ["b", "a", "c"]
      assert Object.keys(Object.put(object, "d", 4)) == ["b", "a", "c", "d"]
    end

    test "delete removes the key and its position" do
      object = Object.new([{"b", 1}, {"a", 2}])
      assert object |> Object.delete("b") |> Object.keys() == ["a"]
    end

    test "merge appends the right object's new keys in order" do
      a = Object.new([{"x", 1}])
      b = Object.new([{"y", 2}, {"x", 9}])
      merged = Object.merge(a, b)
      assert Object.keys(merged) == ["x", "y"]
      assert Object.get(merged, "x") == 9
    end
  end

  describe "reads accept both an Object and a plain map" do
    test "object?/1" do
      assert Object.object?(Object.new())
      assert Object.object?(%{"a" => 1})
      refute Object.object?([1, 2])
      refute Object.object?("s")
    end

    test "get/keys/pairs/size on a plain map fall back to map order" do
      map = %{"a" => 1}
      assert Object.get(map, "a") == 1
      assert Object.get(map, "missing", :default) == :default
      assert Object.keys(map) == ["a"]
      assert Object.pairs(map) == [{"a", 1}]
      assert Object.size(map) == 1
    end
  end

  describe "from_json/1" do
    test "preserves object key order and maps null to nil" do
      {:ok, value} = Object.from_json(~s({"b": 1, "a": {"y": 9, "x": 8}, "n": null}))
      assert Object.keys(value) == ["b", "a", "n"]
      assert value |> Object.get("a") |> Object.keys() == ["y", "x"]
      assert Object.get(value, "n") == nil
    end

    test "decodes arrays as plain lists" do
      assert {:ok, [1, 2, 3]} = Object.from_json("[1,2,3]")
    end
  end

  describe "to_plain/1" do
    test "recursively converts Objects to plain maps" do
      object = Object.new([{"a", Object.new([{"b", 1}])}, {"c", [Object.new([{"d", 2}])]}])
      assert Object.to_plain(object) == %{"a" => %{"b" => 1}, "c" => [%{"d" => 2}]}
    end
  end
end
