defmodule Jsonata.PropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  @keywords ~w(and or in true false null)

  property "integer literals evaluate to themselves" do
    check all(n <- integer()) do
      assert Jsonata.evaluate(Integer.to_string(n)) == {:ok, n}
    end
  end

  property "string literals round-trip through tokenizing (JSON-escaped source)" do
    check all(s <- string(:printable)) do
      assert Jsonata.evaluate(JSON.encode!(s)) == {:ok, s}
    end
  end

  property "integer addition matches Elixir" do
    check all(a <- integer(), b <- integer()) do
      assert Jsonata.evaluate("#{a} + #{b}") == {:ok, a + b}
    end
  end

  property "a single field access returns the bound value" do
    name = filter(string(?a..?z, min_length: 1, max_length: 8), &(&1 not in @keywords))

    check all(field <- name, value <- one_of([integer(), boolean(), string(:alphanumeric)])) do
      assert Jsonata.evaluate(field, %{field => value}) == {:ok, value}
    end
  end

  property "$count of a constructed array equals its length" do
    check all(elements <- list_of(integer(), max_length: 20)) do
      source = "$count([" <> Enum.map_join(elements, ", ", &Integer.to_string/1) <> "])"
      assert Jsonata.evaluate(source) == {:ok, length(elements)}
    end
  end
end
