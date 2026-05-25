defmodule Jsonata.ConformanceScoreboardTest do
  @moduledoc """
  Regression gate on the whole upstream conformance suite.

  Tagged `:conformance` and excluded from the default `mix test` run (it loads
  ~1,400 cases); run it with `mix test --only conformance`. It skips gracefully
  when the `jsonata` submodule is not checked out. Each case is evaluated in its
  own heap-capped, time-limited process so a pathological input fails that one
  case rather than OOMing or hanging the whole run.
  """
  use ExUnit.Case, async: false

  alias Jsonata.Conformance

  @moduletag :conformance

  # The agreed milestone baseline (see MIGRATION.md). Raise this when the score
  # improves; a drop below it fails CI, protecting against silent regressions.
  @baseline 1_389

  @timeout_ms 5_000
  # ~2 GB per worker (64-bit words): kills a runaway case, never the node.
  @max_heap_words 268_435_456

  test "the whole suite passes at or above the baseline (#{@baseline})" do
    if Conformance.available?() do
      root = Conformance.default_root()
      scores = Enum.map(Conformance.groups(root), &score_group(root, &1))

      pass = scores |> Enum.map(& &1.pass) |> Enum.sum()
      total = scores |> Enum.map(& &1.total) |> Enum.sum()

      IO.puts(breakdown(scores, pass, total))

      assert pass >= @baseline,
             "conformance regressed: #{pass} < baseline #{@baseline}\n" <>
               "groups with gaps:\n" <> gaps(scores)
    else
      # The sibling `jsonata` submodule is absent (e.g. a standalone checkout);
      # the fixture-based ConformanceTest covers the loader mechanics.
      IO.puts("[conformance] jsonata submodule not present — skipping scoreboard")
      assert true
    end
  end

  defp score_group(root, group) do
    results = root |> Conformance.load_group(group) |> Enum.map(&passes_isolated?(root, &1))

    %{
      group: group,
      pass: Enum.count(results, &(&1 == true)),
      total: Enum.count(results, &(&1 != :skip))
    }
  end

  # Evaluate one case in a monitored worker with a per-process heap cap so a
  # runaway allocation kills the worker (counted as a failure), not the VM.
  defp passes_isolated?(root, kase) do
    parent = self()

    {pid, ref} =
      spawn_monitor(fn ->
        Process.flag(:max_heap_size, %{size: @max_heap_words, kill: true, error_logger: false})
        send(parent, {:scored, passes?(root, kase)})
      end)

    receive do
      {:scored, result} ->
        Process.demonitor(ref, [:flush])
        result

      {:DOWN, ^ref, _, _, _} ->
        false
    after
      @timeout_ms ->
        Process.exit(pid, :kill)
        false
    end
  end

  defp passes?(root, kase) do
    result =
      try do
        Jsonata.evaluate(kase.expr, Conformance.input(root, kase), kase.bindings)
      rescue
        _ -> {:crash, nil}
      catch
        _, _ -> {:crash, nil}
      end

    case {kase.expected, result} do
      {{:result, expected}, {:ok, actual}} -> Jsonata.Value.deep_equal(actual, expected)
      {:undefined, {:ok, :undefined}} -> true
      {{:error, code}, {:error, %{code: code}}} -> true
      {{:error, _}, {:error, _}} -> true
      {:unspecified, _} -> :skip
      _ -> false
    end
  end

  defp breakdown(scores, pass, total) do
    rows =
      scores
      |> Enum.sort_by(&(&1.total - &1.pass), :desc)
      |> Enum.map(fn s -> "  #{String.pad_trailing(s.group, 30)} #{s.pass}/#{s.total}" end)

    pct = Float.round(pass / total * 100, 1)
    "\nConformance scoreboard: #{pass}/#{total} (#{pct}%)\n" <> Enum.join(rows, "\n")
  end

  defp gaps(scores) do
    scores
    |> Enum.filter(&(&1.pass < &1.total))
    |> Enum.sort_by(&(&1.total - &1.pass), :desc)
    |> Enum.map_join("\n", fn s -> "  #{s.group}: #{s.pass}/#{s.total}" end)
  end
end
