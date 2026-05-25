defmodule Jsonata.TransformTest do
  use ExUnit.Case, async: true

  alias Jsonata.Error

  @data %{
    "Account" => %{
      "Account Name" => "Firefly",
      "Order" => [
        %{
          "OrderID" => "order103",
          "Product" => [
            %{
              "Product Name" => "Bowler Hat",
              "Price" => 34.45,
              "Quantity" => 2,
              "Description" => %{"Colour" => "Purple"}
            },
            %{
              "Product Name" => "Trilby hat",
              "Price" => 21.67,
              "Quantity" => 1,
              "Description" => %{"Colour" => "Orange"}
            }
          ]
        }
      ]
    }
  }

  defp eval(expr) do
    {:ok, result} = Jsonata.evaluate(expr, @data)
    result
  end

  defp products(result), do: get_in(result, ["Account", "Order", Access.at(0), "Product"])

  test "update merges a computed object into each matched node" do
    result = eval(~S'$ ~> |Account.Order.Product|{"Total": Price * Quantity}|')
    assert Enum.map(products(result), & &1["Total"]) == [68.9, 21.67]
    # the rest of the tree is untouched
    assert result["Account"]["Account Name"] == "Firefly"
  end

  test "update can overwrite an existing key" do
    result = eval(~S'$ ~> |Account.Order.Product|{"Price": Price * 2}|')
    assert Enum.map(products(result), & &1["Price"]) == [68.9, 43.34]
  end

  test "delete removes keys from each matched node" do
    result = eval(~S'$ ~> |Account.Order.Product|{}, ["Description", "Quantity"]|')
    [first | _] = products(result)
    refute Map.has_key?(first, "Description")
    refute Map.has_key?(first, "Quantity")
    assert Map.has_key?(first, "Price")
  end

  test "a pattern with no matches returns the input unchanged" do
    assert eval(~S'$ ~> |foo.bar|{"x": 1}|') == @data
  end

  test "undefined input yields undefined" do
    assert {:ok, :undefined} = Jsonata.evaluate(~S'foo ~> |foo.bar|{"x": 1}|', @data)
  end

  test "a positional pattern updates only the selected node" do
    result = eval(~S'$ ~> |(Account.Order.Product)[0]|{"Description": "blah"}|')
    [first, second] = products(result)
    assert first["Description"] == "blah"
    assert second["Description"] == %{"Colour" => "Orange"}
  end

  test "a non-object update raises T2011" do
    assert {:error, %Error{code: "T2011"}} = Jsonata.evaluate(~S'Account ~> |Order|5|', @data)
  end

  test "a non-string delete raises T2012" do
    assert {:error, %Error{code: "T2012"}} = Jsonata.evaluate(~S'Account ~> |Order|{}, 5|', @data)
  end
end
