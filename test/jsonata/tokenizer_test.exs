defmodule Jsonata.TokenizerTest do
  use ExUnit.Case, async: true

  alias Jsonata.{Error, Token, Tokenizer}

  defp tok(source) do
    {:ok, tokens} = Tokenizer.tokenize(source)
    tokens
  end

  defp tv(source), do: Enum.map(tok(source), &{&1.type, &1.value})

  defp err(source) do
    {:error, %Error{} = error} = Tokenizer.tokenize(source)
    error
  end

  describe "structural tokens" do
    test "names and the dot operator in a path" do
      assert tv("a.b.c") == [
               {:name, "a"},
               {:operator, "."},
               {:name, "b"},
               {:operator, "."},
               {:name, "c"}
             ]
    end

    test "empty input yields no tokens" do
      assert tok("") == []
    end

    test "whitespace-only input yields no tokens" do
      assert tok(" \t\n\r\v") == []
    end
  end

  describe "operators" do
    test "every two-character operator" do
      for op <- ~w(.. := != >= <= ** ~> ?: ??) do
        assert [%Token{type: :operator, value: ^op}] = tok(op)
      end
    end

    test "two-character operators take priority over one-character ones" do
      assert tv("a..b") == [{:name, "a"}, {:operator, ".."}, {:name, "b"}]
      assert tv("a:=b") == [{:name, "a"}, {:operator, ":="}, {:name, "b"}]
    end

    test "single-character operators" do
      ops =
        ~w(. [ ] { } , @ # ; : ? + - * % = ^ & ! ~) ++ ["(", ")", "|", "<", ">"]

      for op <- ops do
        assert [%Token{type: :operator, value: ^op}] = tok(op)
      end

      # `/` alone is a regex start unless prefixed; verify it as an operator via next/3.
      assert {:ok, %Token{type: :operator, value: "/"}, _} = Tokenizer.next("/", 0, true)
    end

    test "keyword operators" do
      assert tv("a and b or c in d") == [
               {:name, "a"},
               {:operator, "and"},
               {:name, "b"},
               {:operator, "or"},
               {:name, "c"},
               {:operator, "in"},
               {:name, "d"}
             ]
    end
  end

  describe "literals" do
    test "integers and floats" do
      assert tv("1") == [{:number, 1}]
      assert tv("3.14") == [{:number, 3.14}]
      assert tv("2.5e3") == [{:number, 2500.0}]
      assert tv("1E-2") == [{:number, 0.01}]
    end

    test "number out of range raises S0102" do
      assert %Error{code: "S0102", token: "1e400"} = err("1e400")
    end

    test "boolean and null values" do
      assert tv("true") == [{:value, true}]
      assert tv("false") == [{:value, false}]
      assert tv("null") == [{:value, nil}]
    end

    test "double- and single-quoted strings" do
      assert tv(~s("hello")) == [{:string, "hello"}]
      assert tv("'hello'") == [{:string, "hello"}]
    end

    test "the other quote type is a literal character" do
      assert tv(~s("it's")) == [{:string, "it's"}]
    end

    test "recognized escape sequences" do
      assert tv(~s("a\\tb\\nc\\r\\b\\f\\/\\\\\\"")) == [{:string, "a\tb\nc\r\b\f/\\\""}]
    end

    test "unicode escapes" do
      assert tv(~s("\\u0041\\u00e9")) == [{:string, "Aé"}]
    end

    test "surrogate pairs combine into one codepoint" do
      assert tv(~s("\\uD83D\\uDE00")) == [{:string, "😀"}]
    end

    test "unsupported escape raises S0103" do
      assert %Error{code: "S0103", token: "q"} = err(~s("\\q"))
    end

    test "incomplete unicode escape raises S0104" do
      assert %Error{code: "S0104"} = err(~s("\\u00zz"))
      assert %Error{code: "S0104"} = err(~s("\\u00"))
    end

    test "lone surrogate raises S0104 (Divergence DV-1)" do
      assert %Error{code: "S0104"} = err(~s("\\uD800"))
      assert %Error{code: "S0104"} = err(~s("\\uD800x"))
    end

    test "unterminated string raises S0101" do
      assert %Error{code: "S0101"} = err(~s("oops))
      assert %Error{code: "S0101"} = err(~s("trailing\\))
    end
  end

  describe "names and variables" do
    test "variables strip the leading $" do
      assert tv("$foo") == [{:variable, "foo"}]
    end

    test "the context and root variables" do
      assert tv("$") == [{:variable, ""}]
      assert tv("$$") == [{:variable, "$"}]
    end

    test "backtick-quoted names allow arbitrary characters" do
      assert tv("`weird name`.x") == [{:name, "weird name"}, {:operator, "."}, {:name, "x"}]
    end

    test "unterminated backtick name raises S0105" do
      assert %Error{code: "S0105"} = err("`oops")
    end
  end

  describe "comments" do
    test "block comments are skipped" do
      assert tv("/* a comment */ 1") == [{:number, 1}]
      assert tv("1 /* mid */ + /* end */ 2") == [{:number, 1}, {:operator, "+"}, {:number, 2}]
    end

    test "unterminated comment raises S0106" do
      assert %Error{code: "S0106", position: 0} = err("/* no end")
    end
  end

  describe "regular expressions" do
    test "a regex literal captures pattern and flags" do
      assert [%Token{type: :regex, value: %{pattern: "ab.c", flags: "i"}}] = tok("/ab.c/i")
    end

    test "slashes inside brackets do not end the regex" do
      assert [%Token{type: :regex, value: %{pattern: "a[/]b"}}] = tok("/a[/]b/")
    end

    test "escaped slashes do not end the regex" do
      assert [%Token{type: :regex, value: %{pattern: "a\\/b"}}] = tok(~S(/a\/b/))
    end

    test "empty regex raises S0301" do
      assert %Error{code: "S0301"} = err("//")
    end

    test "unterminated regex raises S0302" do
      assert %Error{code: "S0302"} = err("/abc")
    end
  end

  describe "next/3 prefix disambiguates / " do
    test "with prefix true, / is the division operator" do
      assert {:ok, %Token{type: :operator, value: "/"}, _} = Tokenizer.next("1/2", 1, true)
    end

    test "with prefix false, / begins a regex" do
      assert {:ok, %Token{type: :regex}, _} = Tokenizer.next("/ab/", 0, false)
    end

    test "tokenize/1 treats / after an operand as division" do
      assert tv("a / b") == [{:name, "a"}, {:operator, "/"}, {:name, "b"}]

      assert tv("(a) / b") ==
               [{:operator, "("}, {:name, "a"}, {:operator, ")"}, {:operator, "/"}, {:name, "b"}]
    end

    test "tokenize/1 treats / after an operator as a regex" do
      assert [{:name, "a"}, {:operator, "="}, {:regex, %{pattern: "b"}}] = tv("a = /b/")
    end
  end

  describe "token positions" do
    test "position marks the offset just after each token" do
      assert [
               %Token{value: "ab", position: 2},
               %Token{value: "+", position: 4},
               %Token{value: 12, position: 7}
             ] = tok("ab + 12")
    end
  end
end
