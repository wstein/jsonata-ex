# Micro-benchmarks for the JSONata engine.
#
#   mix run bench/jsonata_bench.exs
#
# Three groups:
#   1. compiled vs. parse+eval, across representative expression shapes
#   2. scaling on a ~10k-node document (incl. the value-equality transform)
#   3. deep recursion (a self-recursive lambda)
#
# Run with a per-process heap cap if you are wary of pathological growth:
#   ERL_FLAGS="+hmax 268435456" mix run bench/jsonata_bench.exs

small =
  %{
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

# ~10,000 product nodes: 100 orders × 100 products.
large =
  %{
    "Account" => %{
      "Account Name" => "Firefly",
      "Order" =>
        for o <- 1..100 do
          %{
            "OrderID" => "order#{o}",
            "Product" =>
              for p <- 1..100 do
                %{"Product Name" => "P#{p}", "Price" => p * 1.5, "Quantity" => rem(p, 4) + 1}
              end
          }
        end
    }
  }

IO.puts("== compiled vs. parse+eval (small doc) ==")

shapes = %{
  "field access" => "Account.`Account Name`",
  "path + arithmetic" => "Account.Order.Product.(Price * Quantity)",
  "predicate + sort" => "Account.Order.Product[Price > 5]^(>Price).`Product Name`",
  "aggregation" => "$sum(Account.Order.Product.(Price * Quantity))",
  "group-by" => "Account.Order.Product{`Product Name`: $sum(Price)}",
  "higher-order" => "$map(Account.Order.Product, function($p) { $p.Price * 2 })"
}

compiled = Map.new(shapes, fn {name, src} -> {name, elem(Jsonata.compile(src), 1)} end)

shapes
|> Enum.flat_map(fn {name, src} ->
  [
    {"#{name} (parse+eval)", fn -> Jsonata.evaluate(src, small) end},
    {"#{name} (compiled)", fn -> Jsonata.evaluate(compiled[name], small) end}
  ]
end)
|> Map.new()
|> Benchee.run(warmup: 1, time: 2, memory_time: 1)

IO.puts("\n== scaling on a ~10k-node document ==")

{:ok, agg} = Jsonata.compile("$sum(Account.Order.Product.(Price * Quantity))")
{:ok, filter} = Jsonata.compile("Account.Order.Product[Price > 100].`Product Name`")
{:ok, xform} = Jsonata.compile("$ ~> |Account.Order.Product|{\"Total\": Price * Quantity}|")

Benchee.run(
  %{
    "aggregate 10k" => fn -> Jsonata.evaluate(agg, large) end,
    "filter 10k" => fn -> Jsonata.evaluate(filter, large) end,
    # exercises the value-equality tree rebuild — watch this as node count grows
    "transform 10k" => fn -> Jsonata.evaluate(xform, large) end
  },
  warmup: 1,
  time: 3,
  memory_time: 1
)

IO.puts("\n== deep recursion (self-recursive lambda) ==")

{:ok, sum_to} =
  Jsonata.compile("($sum := function($n) { $n = 0 ? 0 : $n + $sum($n - 1) }; $sum(depth))")

Benchee.run(
  %{
    "recurse 1k" => fn -> Jsonata.evaluate(sum_to, %{"depth" => 1_000}) end,
    "recurse 5k" => fn -> Jsonata.evaluate(sum_to, %{"depth" => 5_000}) end
  },
  warmup: 1,
  time: 2,
  memory_time: 1
)
