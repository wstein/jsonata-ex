# Cross-runtime benchmark: this Elixir port vs. jsonata-js (the reference).
#
#   cd bench/cross_runtime && npm install   # once, fetches jsonata@2.2.1
#   mix run bench/cross_runtime/compare.exs
#
# Both engines evaluate the *same* expressions against the *same* data; we feed
# the workload to Node as JSON and compare median µs-per-eval side by side. This
# is a like-for-like compiled-expression comparison (no parse cost on either
# side). Treat the ratios as ballpark, not a leaderboard — the engines make
# different number/representation choices (see the README "Differences" section).

data = %{
  "Account" => %{
    "Account Name" => "Firefly",
    "Order" =>
      for o <- 1..20 do
        %{
          "OrderID" => "order#{o}",
          "Product" =>
            for p <- 1..25 do
              %{"Product Name" => "P#{p}", "Price" => p * 1.5, "Quantity" => rem(p, 4) + 1}
            end
        }
      end
  }
}

cases = [
  %{name: "field access", expr: "Account.`Account Name`"},
  %{name: "path + arithmetic", expr: "Account.Order.Product.(Price * Quantity)"},
  %{name: "predicate", expr: "Account.Order.Product[Price > 20].`Product Name`"},
  %{name: "aggregation", expr: "$sum(Account.Order.Product.(Price * Quantity))"},
  %{name: "sort", expr: "Account.Order.Product^(>Price).`Product Name`"},
  %{name: "group-by", expr: "Account.Order.Product{`Product Name`: $sum(Price)}"},
  %{name: "higher-order", expr: "$map(Account.Order.Product, function($p) { $p.Price * 2 })"}
]

# --- this engine (compiled, median µs/eval) ---------------------------------

compiled = Map.new(cases, fn %{name: n, expr: e} -> {n, elem(Jsonata.compile(e), 1)} end)

ex_us =
  Map.new(cases, fn %{name: name} ->
    expr = compiled[name]
    for _ <- 1..50, do: Jsonata.evaluate(expr, data)

    samples =
      for _ <- 1..11 do
        iterations = 200
        {micros, _} = :timer.tc(fn -> for _ <- 1..iterations, do: Jsonata.evaluate(expr, data) end)
        micros / iterations
      end

    {name, Enum.at(Enum.sort(samples), 5)}
  end)

# --- jsonata-js via Node ----------------------------------------------------

script = Path.join(__DIR__, "jsonata_js.mjs")
payload_path = Path.join(System.tmp_dir!(), "jsonata_bench_#{System.unique_integer([:positive])}.json")
File.write!(payload_path, JSON.encode!(%{data: data, cases: cases}))

js_us =
  try do
    case System.cmd("node", [script, payload_path], stderr_to_stdout: false) do
      {out, 0} ->
        out |> JSON.decode!() |> Map.new(fn %{"name" => n, "us" => us} -> {n, us} end)

      {err, _code} ->
        IO.puts("\n[warn] could not run jsonata-js (did you `npm install` in bench/cross_runtime?):")
        IO.puts(err)
        %{}
    end
  after
    File.rm(payload_path)
  end

# --- report -----------------------------------------------------------------

IO.puts("\nMedian µs per eval (compiled expression), lower is better\n")
IO.puts("  #{String.pad_trailing("expression", 20)} #{String.pad_leading("elixir", 10)} #{String.pad_leading("jsonata-js", 12)}   ratio")
IO.puts("  " <> String.duplicate("-", 56))

for %{name: name} <- cases do
  ex = Map.get(ex_us, name)
  js = Map.get(js_us, name)
  ratio = if js && ex && ex > 0, do: "#{Float.round(js / ex, 2)}x", else: "—"
  js_col = if js, do: Float.round(js, 2), else: "n/a"

  IO.puts(
    "  #{String.pad_trailing(name, 20)} #{String.pad_leading(to_string(Float.round(ex, 2)), 10)} " <>
      "#{String.pad_leading(to_string(js_col), 12)}   #{ratio}"
  )
end

IO.puts("\n(ratio = jsonata-js / elixir; >1 means this port is faster on that shape)")
