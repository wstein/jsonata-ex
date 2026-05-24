defmodule Jsonata.FunctionsTest do
  use ExUnit.Case, async: true

  alias Jsonata.Error

  defp eval(expr, input \\ :undefined) do
    {:ok, result} = Jsonata.evaluate(expr, input)
    result
  end

  defp eval_error(expr, input \\ :undefined) do
    {:error, %Error{} = error} = Jsonata.evaluate(expr, input)
    error
  end

  describe "aggregation" do
    test "sum, count, max, min, average" do
      assert eval("$sum([1, 2, 3])") == 6
      assert eval("$count([1, 2, 3])") == 3
      assert eval("$max([3, 1, 2])") == 3
      assert eval("$min([3, 1, 2])") == 1
      assert eval("$average([2, 4])") == 3.0
    end

    test "undefined input yields undefined" do
      assert eval("$sum(missing)", %{}) == :undefined
      assert eval("$count(missing)", %{}) == 0
    end
  end

  describe "numeric" do
    test "number coercion and casting error" do
      assert eval(~s|$number("42")|) == 42
      assert eval(~s|$number("1.5e2")|) == 150.0
      assert eval("$number(true)") == 1
      assert %Error{code: "D3030"} = eval_error(~s|$number("nope")|)
    end

    test "abs, floor, ceil on integers and floats" do
      assert eval("$abs(-5)") == 5
      assert eval("$floor(0)") == 0
      assert eval("$floor(3.7)") == 3
      assert eval("$ceil(3.2)") == 4
      assert eval("$ceil(-3.2)") == -3
    end

    test "round uses banker's rounding" do
      assert eval("$round(2.5)") == 2
      assert eval("$round(3.5)") == 4
      assert eval("$round(2.567, 2)") == 2.57
    end

    test "power and sqrt" do
      assert eval("$power(2, 8)") == 256
      assert eval("$sqrt(16)") == 4
      assert %Error{code: "D3060"} = eval_error("$sqrt(-1)")
    end
  end

  describe "strings" do
    test "case, length, trim" do
      assert eval(~s|$uppercase("ab")|) == "AB"
      assert eval(~s|$lowercase("AB")|) == "ab"
      assert eval(~s|$length("héllo")|) == 5
      assert eval(~s|$trim("  a   b  ")|) == "a b"
    end

    test "substring family" do
      assert eval(~s|$substring("hello", 1, 3)|) == "ell"
      assert eval(~s|$substring("hello", -2)|) == "lo"
      assert eval(~s|$substringBefore("a.b.c", ".")|) == "a"
      assert eval(~s|$substringAfter("a.b.c", ".")|) == "b.c"
    end

    test "pad, contains, split, join, replace" do
      assert eval(~s|$pad("x", 3)|) == "x  "
      assert eval(~s|$pad("x", -3, "0")|) == "00x"
      assert eval(~s|$contains("hello", "ell")|) == true
      assert eval(~s|$split("a,b,c", ",")|) == ["a", "b", "c"]
      assert eval(~s|$join(["a", "b"], "-")|) == "a-b"
      assert eval(~s|$replace("a-b-c", "-", "+")|) == "a+b+c"
      assert eval(~s|$replace("a-b-c", "-", "+", 1)|) == "a+b-c"
    end

    test "context injection uses the input value" do
      assert eval("$uppercase()", "hi") == "HI"
      assert eval("$length()", "abcd") == 4
    end

    test "string serialization" do
      assert eval("$string(5)") == "5"
      assert eval("$string(true)") == "true"
      assert eval("$string([1, 2])") == "[1,2]"
    end
  end

  describe "arrays and objects" do
    test "append, reverse, distinct" do
      assert eval("$append([1, 2], [3])") == [1, 2, 3]
      assert eval("$append(1, 2)") == [1, 2]
      assert eval("$reverse([1, 2, 3])") == [3, 2, 1]
      assert eval("$distinct([1, 2, 2, 3, 1])") == [1, 2, 3]
    end

    test "sort (natural) and its non-comparable error" do
      assert eval("$sort([3, 1, 2])") == [1, 2, 3]
      assert eval(~s|$sort(["c", "a", "b"])|) == ["a", "b", "c"]
      assert %Error{code: "D3070"} = eval_error("$sort([{}, {}])")
    end

    test "zip, lookup, merge" do
      assert eval("$zip([1, 2], [3, 4])") == [[1, 3], [2, 4]]
      assert eval(~s|$lookup({"a": 1}, "a")|) == 1
      assert eval(~s|$merge([{"a": 1}, {"b": 2}])|) == %{"a" => 1, "b" => 2}
    end

    test "exists and type" do
      assert eval("$exists(foo)", %{}) == false
      assert eval("$exists(foo)", %{"foo" => 1}) == true
      assert eval("$type(1)") == "number"
      assert eval(~s|$type("x")|) == "string"
      assert eval("$type([1])") == "array"
      assert eval("$type(null)") == "null"
    end

    test "boolean and not" do
      assert eval("$boolean(0)") == false
      assert eval(~s|$boolean("x")|) == true
      assert eval("$not(false)") == true
    end
  end

  describe "control and errors" do
    test "$error and $assert raise" do
      assert %Error{code: "D3137"} = eval_error(~s|$error("boom")|)
      assert %Error{code: "D3141"} = eval_error(~s|$assert(false, "nope")|)
      assert eval("$assert(true)") == :undefined
    end

    test "invoking a non-function raises T1006" do
      assert %Error{code: "T1006"} = eval_error("$notAFunction()", %{})
    end

    test "a wrong-typed argument raises T0410" do
      assert %Error{code: "T0410"} = eval_error(~s|$abs("x")|)
    end
  end

  describe "url and base64 round-trips" do
    test "base64" do
      assert eval(~s|$base64encode("hi")|) == "aGk="
      assert eval(~s|$base64decode("aGk=")|) == "hi"
    end

    test "url encoding" do
      assert eval(~s|$encodeUrlComponent("a b&c")|) == "a%20b%26c"
      assert eval(~s|$decodeUrlComponent("a%20b%26c")|) == "a b&c"
      assert eval(~s|$encodeUrl("http://x.com/a b")|) =~ "%20"
      assert eval(~s|$decodeUrl("a%20b")|) == "a b"
    end
  end

  describe "object helpers" do
    test "keys over an object and an array of objects" do
      assert eval(~s|$keys({"a": 1, "b": 2})|) |> Enum.sort() == ["a", "b"]
      assert eval(~s|$keys([{"a": 1}, {"b": 2}])|) |> Enum.sort() == ["a", "b"]
    end

    test "spread and array lookup" do
      assert eval(~s|$spread({"a": 1, "b": 2})|) |> length() == 2
      assert eval(~s|$lookup([{"a": 1}, {"a": 2}], "a")|) == [1, 2]
    end

    test "string of an object" do
      assert eval(~s|$string({"a": 1})|) == ~s|{"a":1}|
    end
  end

  describe "undefined propagation" do
    test "scalar functions return undefined for undefined input" do
      exprs = [
        "$uppercase($x)",
        "$abs($x)",
        "$floor($x)",
        "$string($x)",
        "$reverse($x)",
        "$sort($x)",
        "$keys($x)",
        "$distinct($x)",
        "$boolean($x)",
        "$type($x)"
      ]

      for expr <- exprs, do: assert(eval(expr, %{}) == :undefined)
    end

    test "max/min/average of an empty array is undefined" do
      assert eval("$max([])") == :undefined
      assert eval("$average([])") == :undefined
    end
  end

  describe "regular expressions" do
    test "$match returns match objects with groups and char indices" do
      assert eval(~s|$match("ababab", /ab/)|) == [
               %{"match" => "ab", "index" => 0, "groups" => []},
               %{"match" => "ab", "index" => 2, "groups" => []},
               %{"match" => "ab", "index" => 4, "groups" => []}
             ]

      assert eval(~s|$match("a1", /([a-z])([0-9])/).groups|) == ["a", "1"]
    end

    test "$match honors a limit" do
      assert eval(~s|$count($match("aaaa", /a/, 2))|) == 2
    end

    test "regex variants of contains, split, replace" do
      assert eval(~s|$contains("hello", /l+/)|) == true
      assert eval(~s|$split("a1b2c", /[0-9]/)|) == ["a", "b", "c"]
      assert eval(~s|$replace("hello", /l/, "L")|) == "heLLo"
      assert eval(~s|$replace("2024-01", /(\\d+)-(\\d+)/, "$2/$1")|) == "01/2024"
    end

    test "a regex literal is callable and matches the first occurrence" do
      assert eval(~s|/o/("foo")|) == %{"match" => "o", "index" => 1, "groups" => []}
    end
  end

  describe "$eval and host functions" do
    test "$eval parses and evaluates in the current scope" do
      assert eval(~s|$eval("[1,2,3].($*2)")|) == [2, 4, 6]
      assert eval(~s|($x := 5; $eval("$x + 1"))|) == 6
    end

    test "an Elixir function bound as a variable is callable" do
      assert {:ok, 42} =
               Jsonata.evaluate("$double(21)", :undefined, %{"double" => fn n -> n * 2 end})

      assert {:ok, 7} =
               Jsonata.evaluate("$add(3, 4)", :undefined, %{"add" => fn a, b -> a + b end})
    end
  end

  describe "edge cases" do
    test "number of false, string with prettify flag" do
      assert eval("$number(false)") == 0
      assert eval("$string(5, true)") == "5"
    end

    test "split/replace honor the limit argument" do
      assert eval(~s|$split("a,b,c,d", ",", 2)|) == ["a", "b"]
      assert eval(~s|$split("abc", "")|) == ["a", "b", "c"]
    end

    test "substring helpers with no match return the whole string" do
      assert eval(~s|$substringBefore("abc", "x")|) == "abc"
      assert eval(~s|$substringAfter("abc", "x")|) == "abc"
      assert eval(~s|$pad("hello", 3)|) == "hello"
    end

    test "distinct/spread/keys/lookup on non-collections pass through or are undefined" do
      assert eval("$distinct(5)") == 5
      assert eval("$spread(5)") == 5
      assert eval("$keys(5)") == :undefined
      assert eval(~s|$lookup(5, "a")|) == :undefined
      assert eval("$round(2)") == 2
    end

    test "zip stops at the shortest array; type of a function" do
      assert eval("$zip([1, 2, 3], [4])") == [[1, 4]]
      assert eval("$type($uppercase)") == "function"
    end

    test "$error with no message and append with undefined operands" do
      assert %Error{code: "D3137"} = eval_error("$error()")
      assert eval("$append(missing, [1])", %{}) == [1]
      assert eval("$append([1], missing)", %{}) == [1]
    end
  end
end
