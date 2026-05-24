defmodule Jsonata.EvaluatorTest do
  use ExUnit.Case, async: true

  alias Jsonata.Error

  defp eval(expr, input \\ :undefined, bindings \\ %{}) do
    {:ok, result} = Jsonata.evaluate(expr, input, bindings)
    result
  end

  defp eval_error(expr, input \\ :undefined) do
    {:error, %Error{} = error} = Jsonata.evaluate(expr, input)
    error
  end

  @account %{
    "Account" => %{
      "Order" => [
        %{"Product" => [%{"Price" => 10, "Qty" => 2}, %{"Price" => 20, "Qty" => 1}]},
        %{"Product" => [%{"Price" => 5, "Qty" => 4}]}
      ]
    }
  }

  describe "literals" do
    test "scalars" do
      assert eval("1") == 1
      assert eval("2.5") == 2.5
      assert eval(~s("hi")) == "hi"
      assert eval("true") == true
      assert eval("null") == nil
    end
  end

  describe "path navigation" do
    test "field access and nesting" do
      assert eval("a.b", %{"a" => %{"b" => 42}}) == 42
      assert eval("a.b", %{"a" => %{"c" => 1}}) == :undefined
    end

    test "null field values are preserved (not dropped)" do
      assert eval("x.y", %{"x" => %{"y" => nil}}) == nil
    end

    test "arrays flatten through path steps" do
      assert eval("Account.Order.Product.Price", @account) == [10, 20, 5]
    end

    test "a single array result at the last step is preserved" do
      assert eval("a", %{"a" => [1, 2]}) == [1, 2]
      assert eval(~s({"a": [1]}.a)) == [1]
    end

    test "wildcard and descendant" do
      assert eval("*", %{"a" => 1, "b" => 2}) == [1, 2]
      assert eval("**.Price", @account) == [10, 20, 5]
    end
  end

  describe "predicates" do
    test "numeric index, including negative" do
      assert eval("a[0]", %{"a" => [10, 20, 30]}) == 10
      assert eval("a[-1]", %{"a" => [10, 20, 30]}) == 30
      assert eval("a[5]", %{"a" => [10, 20, 30]}) == :undefined
    end

    test "boolean predicate filters" do
      assert eval("Account.Order.Product[Qty > 1].Price", @account) == [10, 5]
    end

    test "top-level array context with an index predicate" do
      data = [%{"a" => [%{"b" => [1]}, %{"b" => [2]}]}, %{"a" => [%{"b" => [3]}]}]
      assert eval("a[0].b", data) == [1]
    end
  end

  describe "operators" do
    test "arithmetic" do
      assert eval("1 + 2 * 3") == 7
      assert eval("10 - 4") == 6
      assert eval("7 % 3") == 1
      assert eval("10 / 4") == 2.5
    end

    test "comparison and equality" do
      assert eval("3 > 2") == true
      assert eval("3 = 3") == true
      assert eval(~s("a" = "a")) == true
      assert eval("3 != 4") == true
      assert eval("1 = 1.0") == true
    end

    test "boolean and/or with truthiness" do
      assert eval("true and false") == false
      assert eval("true or false") == true
      assert eval(~s("" or "x")) == true
    end

    test "inclusion" do
      assert eval("2 in [1, 2, 3]") == true
      assert eval("5 in [1, 2, 3]") == false
    end

    test "string concatenation coerces operands" do
      assert eval(~s("a" & "b")) == "ab"
      assert eval(~s("n=" & 5)) == "n=5"
      assert eval("1 & 2") == "12"
    end

    test "unary minus" do
      assert eval("-5") == -5
      assert eval("-a", %{"a" => 3}) == -3
    end
  end

  describe "constructors and ranges" do
    test "array constructor" do
      assert eval("[1, 2, 3]") == [1, 2, 3]
      assert eval("[]") == []
    end

    test "range" do
      assert eval("[1..5]") == [1, 2, 3, 4, 5]
      assert eval("[5..1]") == []
    end

    test "object constructor" do
      assert eval(~s({"a": 1, "b": 2 + 3})) == %{"a" => 1, "b" => 5}
    end
  end

  describe "conditionals" do
    test "ternary with and without else" do
      assert eval("true ? 1 : 2") == 1
      assert eval("false ? 1 : 2") == 2
      assert eval("false ? 1") == :undefined
    end

    test "default and coalescing operators" do
      assert eval("0 ?: 42") == 42
      assert eval(~s("x" ?: 42)) == "x"
      assert eval("missing ?? 42", %{}) == 42
      assert eval("a ?? 42", %{"a" => 7}) == 7
    end
  end

  describe "blocks, binds, variables" do
    test "block returns the last expression" do
      assert eval("(1; 2; 3)") == 3
    end

    test "variable binding is visible to later block expressions" do
      assert eval("($a := 1; $b := 2; $a + $b)") == 3
    end

    test "nested block scopes" do
      assert eval("($a := 1; $c := ($a := 4; $a + 1); $a + $c)") == 6
    end

    test "context and external bindings" do
      assert eval("$", 5) == 5
      assert eval("$x + 1", :undefined, %{"x" => 10}) == 11
    end
  end

  describe "errors" do
    test "arithmetic on a non-number raises T2001/T2002" do
      assert %Error{code: "T2001"} = eval_error(~s("a" + 1))
      assert %Error{code: "T2002"} = eval_error(~s(1 + "a"))
    end

    test "comparison of mismatched types raises T2009" do
      assert %Error{code: "T2009"} = eval_error(~s(1 < "a"))
    end

    test "negating a non-number raises D1002" do
      assert %Error{code: "D1002"} = eval_error("-a", %{"a" => "x"})
    end

    test "non-integer range bounds raise T2003/T2004" do
      assert %Error{code: "T2003"} = eval_error("[1.5..3]")
      assert %Error{code: "T2004"} = eval_error("[1..3.5]")
    end

    test "comparing a non-comparable value raises T2010" do
      assert %Error{code: "T2010"} = eval_error("a > 1", %{"a" => [1, 2]})
    end
  end

  describe "value coercions" do
    test "concatenation serializes composite values as JSON" do
      assert eval("a & b", %{"a" => [1, 2], "b" => %{"k" => 1}}) == ~s([1,2]{"k":1})
    end

    test "whole-valued floats stringify without a decimal point" do
      assert eval(~s|"" & (10 / 2)|) == "5"
    end

    test "undefined operands concatenate as empty strings" do
      assert eval(~s(missing & "x")) == "x"
    end
  end

  describe "later phases" do
    test "lambda evaluation is not yet implemented" do
      assert_raise RuntimeError, ~r/later phase/, fn ->
        Jsonata.evaluate("function($x){$x}(1)", %{})
      end
    end
  end
end
