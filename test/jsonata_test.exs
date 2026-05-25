defmodule JsonataTest do
  use ExUnit.Case, async: true
  import Jsonata, only: [sigil_JSONATA: 2, sigil_J: 2]
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

  describe "~JSONATA sigil" do
    test "compiles a literal expression at compile time" do
      assert Jsonata.evaluate(~JSONATA"$uppercase(name)", %{"name" => "bob"}) == {:ok, "BOB"}
    end

    test "~J is a short alias for ~JSONATA" do
      assert Jsonata.evaluate(~J"a + b", %{"a" => 2, "b" => 3}) == {:ok, 5}
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

  describe "evaluate/4 resource limits (S8)" do
    test "max_heap_size kills a runaway evaluation" do
      assert {:error, %Error{code: "U1001"}} =
               Jsonata.evaluate("[1..1e7]", :undefined, %{}, max_heap_size: 50_000)
    end

    test "timeout kills a long-running evaluation" do
      expr = "($f := function($n){$n = 0 ? 0 : $f($n - 1)}; $f(50000000))"

      assert {:error, %Error{code: "U1001"}} =
               Jsonata.evaluate(expr, :undefined, %{}, timeout: 200)
    end

    test "a within-limit evaluation returns normally, host functions included" do
      assert {:ok, 5050} =
               Jsonata.evaluate("$sum([1..100])", :undefined, %{}, max_heap_size: 268_435_456)

      assert {:ok, 42} =
               Jsonata.evaluate("$double(21)", :undefined, %{"double" => fn n -> n * 2 end},
                 timeout: 1_000
               )
    end

    test "no limits runs inline (no behaviour change)" do
      assert {:ok, 3} = Jsonata.evaluate("a + b", %{"a" => 1, "b" => 2}, [])
    end
  end
end
