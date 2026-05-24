defmodule Jsonata.ConformanceTest do
  use ExUnit.Case, async: true

  alias Jsonata.Conformance
  alias Jsonata.Conformance.Case, as: C

  @fixtures Path.expand(Path.join([__DIR__, "..", "fixtures", "test-suite"]))

  defp by_name(cases, name), do: Enum.find(cases, &(&1.name == name))

  describe "available?/1" do
    test "true when the suite is present, false otherwise" do
      assert Conformance.available?(@fixtures)
      refute Conformance.available?(Path.join(@fixtures, "does-not-exist"))
    end
  end

  describe "groups/1" do
    test "lists group directories, sorted" do
      assert Conformance.groups(@fixtures) == ["beta", "sample"]
    end
  end

  describe "load/1" do
    setup do
      %{cases: Conformance.load(@fixtures)}
    end

    test "loads every case across all groups", %{cases: cases} do
      assert length(cases) == 8
    end

    test "normalizes a result outcome", %{cases: cases} do
      assert %C{group: "sample", expr: "1 + 1", dataset: "dataset0", expected: {:result, 2}} =
               by_name(cases, "single")
    end

    test "normalizes an error outcome to its code", %{cases: cases} do
      assert by_name(cases, "error").expected == {:error, "D3141"}
    end

    test "normalizes an undefined outcome", %{cases: cases} do
      assert by_name(cases, "undef").expected == :undefined
    end

    test "treats a missing outcome as unspecified", %{cases: cases} do
      assert by_name(cases, "unspecified").expected == :unspecified
    end

    test "resolves expr-file against the group directory", %{cases: cases} do
      file_case = by_name(cases, "exprfile")
      assert String.trim(file_case.expr) == "1 + 2"
      assert file_case.expected == {:result, 3}
    end

    test "expands an array file into indexed cases", %{cases: cases} do
      assert by_name(cases, "multi").expr == "a"
      assert by_name(cases, "multi[1]").expr == "b"
    end

    test "captures inline data and bindings", %{cases: cases} do
      assert by_name(cases, "multi").data == %{"a" => 1}
      assert by_name(cases, "single").bindings == %{}
    end

    test "skips files that are not strict JSON", %{cases: cases} do
      refute by_name(cases, "surrogate")
    end
  end

  describe "decode_failures/1" do
    test "reports files with lone surrogate escapes" do
      assert [{path, _reason}] = Conformance.decode_failures(@fixtures)
      assert Path.basename(path) == "surrogate.json"
    end
  end

  describe "load_group/2" do
    test "loads a single group's cases" do
      names = @fixtures |> Conformance.load_group("beta") |> Enum.map(& &1.name)
      assert names == ["one"]
    end

    test "returns [] for an absent group" do
      assert Conformance.load_group(@fixtures, "no-such-group") == []
    end
  end

  describe "dataset/2" do
    test "decodes a named dataset" do
      assert Conformance.dataset(@fixtures, "dataset0") == %{"hello" => "world"}
    end
  end

  describe "the real upstream suite" do
    @describetag :integration

    test "loads when the jsonata submodule is checked out" do
      if Conformance.available?() do
        cases = Conformance.load()
        assert length(cases) > 1200
        assert Enum.all?(cases, &is_binary(&1.expr))
        assert Conformance.default_root() =~ "test-suite"
      else
        # The sibling `jsonata` submodule is not present (e.g. standalone CI);
        # the fixture-based tests above cover the loader logic.
        :ok
      end
    end

    test "the only decode failures are the known lone-surrogate cases" do
      if Conformance.available?() do
        names =
          Conformance.decode_failures()
          |> Enum.map(fn {path, _} ->
            Path.basename(Path.dirname(path)) <> "/" <> Path.basename(path)
          end)
          |> Enum.sort()

        assert names == [
                 "function-encodeUrl/case002.json",
                 "function-encodeUrlComponent/case002.json"
               ]
      else
        :ok
      end
    end
  end
end
