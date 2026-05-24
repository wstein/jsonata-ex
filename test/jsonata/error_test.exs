defmodule Jsonata.ErrorTest do
  use ExUnit.Case, async: true

  alias Jsonata.Error

  test "new/2 renders the message template and keeps metadata" do
    error = Error.new("S0101", position: 5)
    assert error.code == "S0101"
    assert error.position == 5
    assert error.message == "String literal must be terminated by a matching quote"
  end

  test "new/2 substitutes the {{token}} placeholder" do
    assert Error.new("S0102", token: "1e400").message == "Number out of range: 1e400"
  end

  test "new/2 coerces a non-binary token to a string" do
    assert Error.new("S0102", token: 42).message == "Number out of range: 42"
  end

  test "an unknown code falls back to the code as its message" do
    assert Error.new("Z9999").message == "Z9999"
  end

  test "template/1 exposes known templates and nil otherwise" do
    assert Error.template("S0106") == "Comment has no closing tag"
    assert Error.template("nope") == nil
  end

  test "it is a raisable exception" do
    assert_raise Error, "Empty regular expressions are not allowed", fn ->
      raise Error, code: "S0301"
    end
  end
end
