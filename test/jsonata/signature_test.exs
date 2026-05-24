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
end
