defmodule Jsonata.SignatureTest do
  use ExUnit.Case, async: true

  alias Jsonata.{Error, Signature}

  defp validate(sig, args, context \\ :undefined) do
    Signature.validate(Signature.parse(sig), args, context, "fn")
  end

  test "validates and passes through matching arguments" do
    assert validate("<ns:x>", [1, "a"]) == [1, "a"]
  end

  test "wraps a singleton for an array parameter" do
    assert validate("<a:a>", [5]) == [[5]]
    assert validate("<a:a>", [[1, 2]]) == [[1, 2]]
  end

  test "substitutes the context value for a missing - parameter" do
    assert validate("<s-:s>", [], "ctx") == ["ctx"]
    assert validate("<s-:s>", ["explicit"], "ctx") == ["explicit"]
  end

  test "missing optional parameter becomes :undefined" do
    assert validate("<s-nn?:s>", ["a", 1]) == ["a", 1, :undefined]
  end

  test "raises T0411 when the context type is incompatible" do
    assert_raise Error, fn -> validate("<n-:n>", [], "not a number") end
  end

  test "raises T0410 when an argument type does not match" do
    error = catch_error(validate("<n:n>", ["x"]))
    assert error.code == "T0410"
    assert error.message =~ "Argument 1"
  end

  test "supports choice and variadic parameters" do
    assert validate("<(sn)+:x>", [1, "a", 2]) == [1, "a", 2]
  end

  describe "parse/1 edge cases" do
    test "signature with no closing > returns empty params (line 57 fallback)" do
      # pos reaches byte_size(signature) without hitting ":" or ">"
      sig = Signature.parse("<")
      assert sig.params == []
    end

    test "unknown symbol in signature is skipped (line 100 catch-all)" do
      # '#' is not a recognized symbol; it should be skipped
      sig = Signature.parse("<#n>")
      assert length(sig.params) == 1
      assert hd(sig.params).type == "n"
    end

    test "nested subtype <a<n>> exercises closing_bracket depth tracking" do
      # Parsing '<' inside a signature triggers depth > 1 in closing_bracket
      # covering the depth-decrement (line 118) and depth-increment (line 119) branches
      sig = Signature.parse("<a<n>>")
      assert length(sig.params) == 1
      [param] = sig.params
      assert param.type == "a"
      assert param.subtype == "n"
    end
  end

  describe "symbol/1 dispatch edge cases" do
    alias Jsonata.Sequence

    test "native Elixir function maps to 'f' (line 174)" do
      # A raw Elixir fn (not a %Function{} struct) must also map to type "f"
      sig = Signature.parse("<f>")
      native_fn = fn -> :ok end
      assert Signature.validate(sig, [native_fn], nil, "test") == [native_fn]
    end

    test "Sequence argument maps to 'a' (line 180)" do
      sig = Signature.parse("<a>")
      seq = Sequence.from_value([1, 2, 3])
      assert Signature.validate(sig, [seq], nil, "test") == [seq]
    end

    test "empty Sequence argument maps to 'm' / undefined (line 180 empty branch)" do
      # An empty Sequence is treated as undefined (missing) by the symbol dispatch
      sig = Signature.parse("<a?>")
      empty_seq = Sequence.empty()
      # Empty sequence → "m" (missing) — matches "a?" → :undefined
      result = Signature.validate(sig, [empty_seq], nil, "test")
      assert result == [:undefined]
    end

    test "exotic atom (not nil/:undefined) maps to 'm' via catch-all (line 183)" do
      # A plain atom that isn't nil or :undefined hits the symbol/1 catch-all
      sig = Signature.parse("<n?>")
      # :some_atom → "m" (missing), matches "n?" optional
      result = Signature.validate(sig, [:some_atom], nil, "test")
      assert result == [:some_atom]
    end
  end
end
