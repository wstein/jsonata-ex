defmodule Jsonata.EnvironmentTest do
  use ExUnit.Case, async: true

  alias Jsonata.Environment

  test "root binds the input to $" do
    env = Environment.root(%{"a" => 1})
    assert Environment.lookup(env, "$") == %{"a" => 1}
  end

  test "bind returns a new environment; lookup finds the value" do
    env = Environment.root(nil) |> Environment.bind("x", 7)
    assert Environment.lookup(env, "x") == 7
  end

  test "lookup walks the parent chain" do
    parent = Environment.root(nil) |> Environment.bind("x", 1)
    child = parent |> Environment.child() |> Environment.bind("y", 2)
    assert Environment.lookup(child, "x") == 1
    assert Environment.lookup(child, "y") == 2
  end

  test "a child binding shadows the parent" do
    parent = Environment.root(nil) |> Environment.bind("x", 1)
    child = parent |> Environment.child() |> Environment.bind("x", 99)
    assert Environment.lookup(child, "x") == 99
    assert Environment.lookup(parent, "x") == 1
  end

  test "an unbound name resolves to :undefined" do
    assert Environment.lookup(Environment.root(nil), "nope") == :undefined
  end
end
