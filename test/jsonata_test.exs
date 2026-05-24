defmodule JsonataTest do
  use ExUnit.Case, async: true
  import Jsonata, only: [sigil_J: 2]
  doctest Jsonata

  alias Jsonata.{Error, Expression}

  test "version/0 reports the application version" do
    assert Jsonata.version() == "0.1.0"
  end

  describe "compile/1" do
    test "returns a reusable compiled expression" do
      assert {:ok, %Expression{source: "a + b"} = compiled} = Jsonata.compile("a + b")
      assert Jsonata.evaluate(compiled, %{"a" => 1, "b" => 2}) == {:ok, 3}
      assert Jsonata.evaluate(compiled, %{"a" => 10, "b" => 20}) == {:ok, 30}
    end

    test "reports a parse error" do
      assert {:error, %Error{code: "S0201"}} = Jsonata.compile("1 2")
    end
  end

  describe "~J sigil" do
    test "compiles a literal expression at compile time" do
      assert Jsonata.evaluate(~J"$uppercase(name)", %{"name" => "bob"}) == {:ok, "BOB"}
    end
  end

  describe "evaluate/3" do
    test "accepts a string or a compiled expression" do
      assert Jsonata.evaluate("$sum([1, 2, 3])") == {:ok, 6}
      {:ok, compiled} = Jsonata.compile("$sum([1, 2, 3])")
      assert Jsonata.evaluate(compiled) == {:ok, 6}
    end

    test "surfaces parse errors from a string expression" do
      assert {:error, %Error{}} = Jsonata.evaluate("a +", %{})
    end
  end
end
