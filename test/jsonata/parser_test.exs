defmodule Jsonata.ParserTest do
  use ExUnit.Case, async: true

  alias Jsonata.{Conformance, Error, Parser}

  defp ast(source) do
    {:ok, ast} = Parser.parse(source)
    ast
  end

  defp error(source) do
    {:error, %Error{} = error} = Parser.parse(source)
    error
  end

  describe "literals" do
    test "numbers, strings, and values" do
      assert %{type: :number, value: 1} = ast("1")
      assert %{type: :number, value: 2.5} = ast("2.5")
      assert %{type: :string, value: "hi"} = ast(~s("hi"))
      assert %{type: :value, value: true} = ast("true")
      assert %{type: :value, value: nil} = ast("null")
    end
  end

  describe "paths" do
    test "dotted fields become a path of name steps" do
      assert %{type: :path, steps: [%{type: :name, value: "a"}, %{type: :name, value: "b"}]} =
               ast("a.b")
    end

    test "string steps are rewritten to names" do
      assert %{type: :path, steps: [_, %{type: :name, value: "b c"}]} = ast("a.`b c`")
    end

    test "numbers and values cannot be path steps" do
      assert %Error{code: "S0213"} = error("a.1")
      assert %Error{code: "S0213"} = error("a.true")
    end

    test "wildcard and descendant steps" do
      assert %{type: :path, steps: [_, %{type: :descendant}, _]} = ast("foo.**.baz")
      assert %{type: :wildcard} = ast("*")
    end
  end

  describe "predicates" do
    test "a predicate on a path step becomes a filter stage" do
      assert %{type: :path, steps: [_, %{type: :name, value: "b", stages: [%{type: :filter}]}]} =
               ast("a.b[x=1]")
    end

    test "an empty predicate sets keep_array" do
      assert %{keep_array: true} = ast("a[]")
    end
  end

  describe "operators and precedence" do
    test "multiplication binds tighter than addition" do
      assert %{type: :binary, value: "+", rhs: %{type: :binary, value: "*"}} = ast("1 + 2 * 3")
    end

    test "comparison, boolean, inclusion, and concatenation" do
      assert %{type: :binary, value: "="} = ast("a = b")
      assert %{type: :binary, value: "and"} = ast("a and b")
      assert %{type: :binary, value: "in"} = ast("1 in [1, 2]")
      assert %{type: :binary, value: "&"} = ast(~s("a" & "b"))
    end

    test "unary minus on a literal folds into the number" do
      assert %{type: :number, value: -5} = ast("-5")
    end

    test "unary minus on an expression stays a unary node" do
      assert %{type: :unary, value: "-", expression: %{type: :path}} = ast("-a.b")
    end
  end

  describe "constructors" do
    test "array constructor" do
      assert %{type: :unary, value: "[", expressions: [_, _]} = ast("[1, 2]")
    end

    test "range inside an array constructor" do
      assert %{type: :unary, value: "[", expressions: [%{type: :binary, value: ".."}]} =
               ast("[1..5]")
    end

    test "object constructor" do
      assert %{type: :unary, value: "{", lhs: [[%{type: :string}, %{type: :binary, value: "+"}]]} =
               ast(~s({"k": 1 + 1}))
    end
  end

  describe "blocks, binds, conditionals" do
    test "block of expressions" do
      assert %{type: :block, expressions: [_, _, _]} = ast("(1; 2; 3)")
    end

    test "variable binding inside a block" do
      assert %{type: :block, expressions: [%{type: :bind}, %{type: :variable, value: "a"}]} =
               ast("($a := 1; $a)")
    end

    test "ternary, default and coalescing operators" do
      assert %{type: :condition, condition: _, then: _, else: _} = ast("a ? b : c")
      assert %{type: :condition, else: _} = ast("a ?: b")
      assert %{type: :coalesce, lhs: _, rhs: _} = ast("a ?? b")
    end
  end

  describe "functions and lambdas (parsed; evaluated in later phases)" do
    test "function invocation" do
      assert %{type: :function, procedure: %{type: :variable, value: "sum"}, arguments: [_]} =
               ast("$sum(items)")
    end

    test "lambda definition" do
      assert %{type: :lambda, arguments: [%{type: :variable, value: "x"}], body: _} =
               ast("function($x){ $x * 2 }")
    end

    test "lambda with a type signature" do
      assert %{type: :lambda, signature: "<n:n>"} = ast("function($x)<n:n>{ $x }")
    end

    test "a non-variable lambda parameter raises S0208" do
      assert %Error{code: "S0208"} = error("function($x, 2){ $x }")
    end
  end

  describe "variables" do
    test "named, context, and root variables" do
      assert %{type: :variable, value: "x"} = ast("$x")
      assert %{type: :variable, value: ""} = ast("$")
      assert %{type: :variable, value: "$"} = ast("$$")
    end
  end

  describe "syntax errors" do
    test "an operator used as a prefix raises S0211" do
      assert %Error{code: "S0211"} = error("= 1")
    end

    test "mismatched and missing closers" do
      assert %Error{code: "S0202"} = error("(1]")
      assert %Error{code: "S0203"} = error("(1")
    end

    test "trailing tokens raise S0201" do
      assert %Error{code: "S0201"} = error("1 2")
    end

    test "the left side of := must be a variable" do
      assert %Error{code: "S0212"} = error("1 := 2")
    end
  end

  describe "conformance corpus" do
    test "every in-scope case expecting a result parses without error" do
      groups = ~w(literals fields comparison-operators boolean-expresssions
                  inclusion-operator coalescing-operator default-operator array-constructor)

      failures =
        for group <- groups,
            kase <- Conformance.load_group(group),
            match?({:result, _}, kase.expected) or kase.expected == :undefined,
            match?({:error, _}, Parser.parse(kase.expr)),
            do: {group, kase.expr}

      assert failures == []
    end
  end
end
