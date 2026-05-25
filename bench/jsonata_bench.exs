# Micro-benchmarks for the JSONata engine.
#
#   mix run bench/jsonata_bench.exs
#
# Compares evaluating a freshly-parsed string against reusing a compiled
# expression, across a few representative expression shapes, to show the value
# of `Jsonata.compile/1`.

data = %{
  "Account" => %{
    "Account Name" => "Firefly",
    "Order" =>
      for o <- 1..5 do
        %{
          "OrderID" => "order#{o}",
          "Product" =>
            for p <- 1..10 do
              %{"Product Name" => "P#{p}", "Price" => p * 1.5, "Quantity" => rem(p, 4) + 1}
            end
        }
      end
  }
}

expressions = %{
  "field access" => "Account.`Account Name`",
  "path + arithmetic" => "Account.Order.Product.(Price * Quantity)",
  "predicate + sort" => "Account.Order.Product[Price > 5]^(>Price).`Product Name`",
  "aggregation" => "$sum(Account.Order.Product.(Price * Quantity))",
  "group-by" => "Account.Order.Product{`Product Name`: $sum(Price)}",
  "higher-order" => "$map(Account.Order.Product, function($p) { $p.Price * 2 })"
}

compiled =
  Map.new(expressions, fn {name, source} ->
    {:ok, expr} = Jsonata.compile(source)
    {name, expr}
  end)

jobs =
  Enum.flat_map(expressions, fn {name, source} ->
    [
      {"#{name} (parse + eval)", fn -> Jsonata.evaluate(source, data) end},
      {"#{name} (compiled)", fn -> Jsonata.evaluate(compiled[name], data) end}
    ]
  end)
  |> Map.new()

Benchee.run(jobs, warmup: 1, time: 3, memory_time: 1)
