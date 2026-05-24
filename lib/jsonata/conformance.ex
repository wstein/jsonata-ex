defmodule Jsonata.Conformance do
  @moduledoc """
  Loader for the upstream `jsonata-js` conformance suite.

  The suite is a language-agnostic set of JSON cases under
  `test-suite/groups/<group>/*.json`, with shared inputs under
  `test-suite/datasets/`. Each case declares an `expr` (or `expr-file`), an
  input (inline `data` or a named `dataset`), `bindings`, and an expected
  outcome (`result`, `error`, or `undefinedResult`). A single case file holds
  one case; some files hold an array of cases.

  This module reads and normalizes those files into `Case` structs so the test
  harness can drive the engine against them. It does **not** evaluate anything.

  A handful of upstream files embed lone UTF-16 surrogate escapes (e.g.
  `"\\uD800"`), which JavaScript's `JSON.parse` accepts but a strict UTF-8 JSON
  decoder cannot represent. Such files are skipped by `load/1` and reported by
  `decode_failures/1` rather than silently dropped (see the Divergence Register
  in `../MIGRATION.md`).
  """

  defmodule Case do
    @moduledoc "A single normalized conformance case."

    @typedoc """
    Expected outcome of a case:

      * `{:result, value}` — the expression must evaluate to `value`
      * `{:error, code}` — evaluation must raise the JSONata error `code`
        (`code` is `nil` when only a message is given upstream)
      * `:undefined` — the result must be JSONata "nothing"
      * `:unspecified` — the file declares no outcome
    """
    @type expected ::
            {:result, term()} | {:error, String.t() | nil} | :undefined | :unspecified

    @type t :: %__MODULE__{
            group: String.t(),
            name: String.t(),
            expr: String.t(),
            dataset: String.t() | nil,
            data: term(),
            bindings: %{optional(String.t()) => term()},
            expected: expected()
          }

    @enforce_keys [:group, :name, :expr, :expected]
    defstruct [:group, :name, :expr, :dataset, :data, :expected, bindings: %{}]
  end

  @default_root Path.expand(
                  Path.join([__DIR__, "..", "..", "..", "jsonata", "test", "test-suite"])
                )

  @doc "Default location of the conformance suite (in the sibling `jsonata` submodule)."
  @spec default_root() :: String.t()
  def default_root, do: @default_root

  @doc "Returns `true` when the conformance suite is present at `root`."
  @spec available?(String.t()) :: boolean()
  def available?(root \\ @default_root), do: File.dir?(Path.join(root, "groups"))

  @doc "Lists the group names found under `root`."
  @spec groups(String.t()) :: [String.t()]
  def groups(root \\ @default_root) do
    root
    |> Path.join("groups")
    |> File.ls!()
    |> Enum.filter(&File.dir?(Path.join([root, "groups", &1])))
    |> Enum.sort()
  end

  @doc """
  Loads and normalizes every decodable case in the suite at `root`.

  Files that cannot be decoded as strict JSON are skipped; use
  `decode_failures/1` to inspect them. Raises if `root` does not contain a
  `groups` directory; guard with `available?/1` for environments where the
  submodule may be absent.
  """
  @spec load(String.t()) :: [Case.t()]
  def load(root \\ @default_root) do
    for {path, group, group_dir} <- files(root),
        {:ok, decoded} <- [JSON.decode(File.read!(path))],
        kase <- normalize(decoded, path, group, group_dir),
        do: kase
  end

  @doc """
  Returns `{path, reason}` for every suite file that fails strict JSON decoding.

  Used to audit the lone-surrogate divergence; an empty list is expected for any
  UTF-8-clean suite.
  """
  @spec decode_failures(String.t()) :: [{String.t(), term()}]
  def decode_failures(root \\ @default_root) do
    for {path, _group, _group_dir} <- files(root),
        {:error, reason} <- [JSON.decode(File.read!(path))],
        do: {path, reason}
  end

  @doc """
  Loads the decodable cases for a single `group`, or `[]` if the group (or the
  whole suite) is absent.
  """
  @spec load_group(String.t(), String.t()) :: [Case.t()]
  def load_group(root \\ @default_root, group) do
    dir = Path.join([root, "groups", group])

    if File.dir?(dir) do
      for path <- dir |> Path.join("*.json") |> Path.wildcard() |> Enum.sort(),
          {:ok, decoded} <- [JSON.decode(File.read!(path))],
          kase <- normalize(decoded, path, group, dir),
          do: kase
    else
      []
    end
  end

  @doc "Loads and decodes a named dataset (without the `.json` extension)."
  @spec dataset(String.t(), String.t()) :: term()
  def dataset(root \\ @default_root, name) do
    root
    |> Path.join(["datasets/", name, ".json"])
    |> File.read!()
    |> JSON.decode!()
  end

  defp files(root) do
    for group <- groups(root),
        path <- root |> Path.join(["groups/", group, "/*.json"]) |> Path.wildcard() |> Enum.sort() do
      {path, group, Path.join([root, "groups", group])}
    end
  end

  defp normalize(decoded, path, group, group_dir) do
    base = Path.basename(path, ".json")

    decoded
    |> List.wrap()
    |> Enum.with_index()
    |> Enum.map(fn {raw, index} ->
      name = if index == 0, do: base, else: "#{base}[#{index}]"
      build_case(raw, group, name, group_dir)
    end)
  end

  defp build_case(raw, group, name, group_dir) when is_map(raw) do
    %Case{
      group: group,
      name: name,
      expr: expr(raw, group_dir),
      dataset: raw["dataset"],
      data: Map.get(raw, "data"),
      bindings: Map.get(raw, "bindings", %{}),
      expected: expected(raw)
    }
  end

  defp expr(%{"expr" => expr}, _group_dir) when is_binary(expr), do: expr

  defp expr(%{"expr-file" => file}, group_dir) when is_binary(file) do
    group_dir |> Path.join(file) |> File.read!()
  end

  defp expected(raw) do
    cond do
      Map.get(raw, "undefinedResult") == true -> :undefined
      Map.has_key?(raw, "error") -> {:error, get_in(raw, ["error", "code"])}
      Map.has_key?(raw, "result") -> {:result, raw["result"]}
      true -> :unspecified
    end
  end
end
