defmodule Jsonata.ParentOperatorTest do
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
              "Quantity" => 2,
              "Price" => 34.45,
              "SKU" => "0406654608"
            },
            %{
              "Product Name" => "Trilby hat",
              "Quantity" => 1,
              "Price" => 21.67,
              "SKU" => "0406634348"
            }
          ]
        },
        %{
          "OrderID" => "order104",
          "Product" => [
            %{
              "Product Name" => "Bowler Hat",
              "Quantity" => 4,
              "Price" => 34.45,
              "SKU" => "040657863"
            },
            %{
              "Product Name" => "Cloak",
              "Quantity" => 1,
              "Price" => 107.99,
              "SKU" => "0406654603"
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

  defp eval_error(expr) do
    {:error, %Error{} = error} = Jsonata.evaluate(expr, @data)
    error
  end

  test "parent context in an array/object constructor step" do
    assert eval("Account.Order.Product.{ `Product Name`: %.OrderID }") == [
             %{"Bowler Hat" => "order103"},
             %{"Trilby hat" => "order103"},
             %{"Bowler Hat" => "order104"},
             %{"Cloak" => "order104"}
           ]
  end

  test "parent in a predicate" do
    assert eval("Account.Order.Product[%.OrderID='order104'].SKU") == ["040657863", "0406654603"]
  end

  test "multiple levels of parent (%.%)" do
    assert eval("Account.Order.Product[%.%.`Account Name`='Firefly'].SKU") ==
             ["0406654608", "0406634348", "040657863", "0406654603"]

    assert eval("Account.Order.Product.Price[%.%.OrderID='order103']") == [34.45, 21.67]
  end

  test "parent through a block step" do
    assert eval("Account.Order.(Product).{ `Product Name`: %.OrderID }") == [
             %{"Bowler Hat" => "order103"},
             %{"Trilby hat" => "order103"},
             %{"Bowler Hat" => "order104"},
             %{"Cloak" => "order104"}
           ]
  end

  test "parent as a step within the path" do
    assert eval("Account.Order.Product.Price.%[%.OrderID='order103'].SKU") ==
             ["0406654608", "0406634348"]
  end

  test "parent key in a group-by" do
    assert eval("Account.Order.Product.{ %.OrderID: Price * Quantity }") == [
             %{"order103" => 68.9},
             %{"order103" => 21.67},
             %{"order104" => 137.8},
             %{"order104" => 107.99}
           ]
  end

  test "deriving the parent at the top level is an error (S0217)" do
    assert %Error{code: "S0217"} = eval_error("%")
    assert %Error{code: "S0217"} = eval_error("(%)")
  end

  test "% is still the modulo operator in infix position" do
    assert {:ok, [0, 2, 4, 6, 8]} = Jsonata.evaluate("[0..9][$ % 2 = 0]")
  end
end
