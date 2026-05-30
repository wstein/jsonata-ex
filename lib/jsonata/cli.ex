defmodule Jsonata.CLI do
  @moduledoc false

  alias Jsonata.{Function, Functions, Sequence}

  @undefined :undefined

  # escript entry point — System.halt satisfies the no_return escript contract.
  def main(argv), do: System.halt(execute(argv))

  # Testable entry point — returns the exit code without halting.
  @doc false
  @spec execute([String.t()]) :: non_neg_integer()
  def execute(argv) do
    try do
      do_execute(argv)
    catch
      {:cli_exit, code} -> code
    end
  end

  defp do_execute(argv) do
    {bindings, argv} = extract_var_bindings(argv)

    {opts, args, invalid} =
      OptionParser.parse(argv,
        strict: [
          compact: :boolean,
          raw_output: :boolean,
          null_input: :boolean,
          exit_status: :boolean,
          version: :boolean,
          help: :boolean
        ],
        aliases: [c: :compact, r: :raw_output, n: :null_input, e: :exit_status, h: :help]
      )

    for {flag, _} <- invalid do
      IO.puts(:stderr, "jsonata: unknown option #{flag}")
    end

    cond do
      opts[:version] ->
        IO.puts("jsonata #{Jsonata.version()}")
        0

      opts[:help] ->
        print_help()
        0

      args == [] ->
        IO.puts(:stderr, "jsonata: no expression given. Try --help.")
        halt!(1)

      true ->
        [expression | files] = args
        run(expression, files, bindings, opts)
    end
  end

  defp run(expression, files, bindings, opts) do
    inputs = get_inputs(files, opts[:null_input])
    pretty = !opts[:compact]
    raw = opts[:raw_output] || false
    check_exit = opts[:exit_status] || false

    exit_code =
      Enum.reduce(inputs, 0, fn input, code ->
        case Jsonata.evaluate(expression, input, bindings) do
          {:ok, @undefined} ->
            code

          {:ok, result} ->
            IO.puts(format_result(result, pretty, raw))
            if check_exit and falsy?(result), do: 1, else: code

          {:error, error} ->
            IO.puts(:stderr, "jsonata: #{Exception.message(error)}")
            halt!(5)
        end
      end)

    if exit_code != 0, do: halt!(exit_code)
    0
  end

  defp get_inputs(_files, true), do: [nil]
  defp get_inputs([], _null_input), do: [read_stdin()]
  defp get_inputs(files, _null_input), do: Enum.map(files, &read_file/1)

  defp read_stdin do
    IO.read(:stdio, :eof)
    |> decode_json!("<stdin>")
  end

  defp read_file(path) do
    case File.read(path) do
      {:ok, contents} ->
        decode_json!(contents, path)

      {:error, reason} ->
        IO.puts(:stderr, "jsonata: #{path}: #{:file.format_error(reason)}")
        halt!(2)
    end
  end

  # Fix 3: Use Jsonata.decode to preserve object key insertion order.
  defp decode_json!(text, source) do
    case Jsonata.decode(text) do
      {:ok, value} ->
        value

      {:error, _reason} ->
        IO.puts(:stderr, "jsonata: invalid JSON from #{source}")
        halt!(3)
    end
  end

  # Pre-pass to extract --arg / --argjson pairs before OptionParser sees argv,
  # since each flag takes two positional values (name, then value/json).
  defp extract_var_bindings(argv), do: extract_var_bindings(argv, %{}, [])

  # Fix 4: Reject flag-like tokens as the value so --arg name --flag expr
  # doesn't silently consume --flag as the variable's string value.
  defp extract_var_bindings(["--arg", name, value | rest], bindings, acc) do
    if String.starts_with?(value, "--") do
      IO.puts(:stderr, "jsonata: --arg '#{name}': missing value (got flag '#{value}')")
      halt!(1)
    end

    extract_var_bindings(rest, Map.put(bindings, name, value), acc)
  end

  defp extract_var_bindings(["--argjson", name, json | rest], bindings, acc) do
    if String.starts_with?(json, "--") do
      IO.puts(:stderr, "jsonata: --argjson '#{name}': missing JSON value (got flag '#{json}')")
      halt!(1)
    end

    value =
      case JSON.decode(json) do
        {:ok, v} ->
          v

        {:error, _} ->
          IO.puts(:stderr, "jsonata: --argjson #{name}: invalid JSON value")
          halt!(1)
      end

    extract_var_bindings(rest, Map.put(bindings, name, value), acc)
  end

  defp extract_var_bindings(["--arg" | _], _bindings, _acc) do
    IO.puts(:stderr, "jsonata: --arg requires two arguments: name value")
    halt!(1)
  end

  defp extract_var_bindings(["--argjson" | _], _bindings, _acc) do
    IO.puts(:stderr, "jsonata: --argjson requires two arguments: name json")
    halt!(1)
  end

  defp extract_var_bindings([arg | rest], bindings, acc),
    do: extract_var_bindings(rest, bindings, [arg | acc])

  defp extract_var_bindings([], bindings, acc),
    do: {bindings, Enum.reverse(acc)}

  # Throw-based exit so all CLI logic is testable without halting the VM.
  defp halt!(code), do: throw({:cli_exit, code})

  # -- Output formatting ------------------------------------------------------

  defp format_result(%Sequence{} = seq, pretty, raw),
    do: format_result(Sequence.to_value(seq), pretty, raw)

  defp format_result(value, _pretty, true) when is_binary(value), do: value
  defp format_result(value, pretty, _raw), do: encode_json(value, pretty, 0)

  defp encode_json(nil, _, _), do: "null"
  defp encode_json(true, _, _), do: "true"
  defp encode_json(false, _, _), do: "false"
  # Fix 1a: delegate to the library's own number formatter so whole floats like
  # 2.0 render as "2", matching JSONata's $string() and the JS reference output.
  defp encode_json(n, _, _) when is_number(n), do: Functions.number_to_string(n)
  defp encode_json(s, _, _) when is_binary(s), do: JSON.encode!(s)
  # Fix 1b: function values render as the empty JSON string (JS JSON.stringify
  # behaviour for functions).
  defp encode_json(%Function{}, _, _), do: "\"\""

  defp encode_json(list, pretty, depth) when is_list(list) do
    encode_container(list, "[", "]", pretty, depth, &encode_json(&1, pretty, depth + 1))
  end

  # Fix 1c: guard against structs — is_map/1 matches any struct, so without
  # not is_struct/1 a leaked %Function{} or %Sequence{} would emit __struct__
  # and internal field names as JSON keys.
  defp encode_json(map, pretty, depth) when is_map(map) and not is_struct(map) do
    encode_container(Map.to_list(map), "{", "}", pretty, depth, fn {k, v} ->
      JSON.encode!(to_string(k)) <>
        if(pretty, do: ": ", else: ":") <> encode_json(v, pretty, depth + 1)
    end)
  end

  defp encode_container(items, open, close, pretty, depth, encode_fn) do
    case Enum.map(items, encode_fn) do
      [] ->
        open <> close

      encoded when pretty ->
        pad = String.duplicate("  ", depth + 1)
        inner = Enum.map_join(encoded, ",\n", &(pad <> &1))
        open <> "\n" <> inner <> "\n" <> String.duplicate("  ", depth) <> close

      encoded ->
        open <> Enum.join(encoded, ",") <> close
    end
  end

  # Fix 2: delegate to the evaluator's own truth table so 0, "", and {} are
  # correctly falsy, matching JSONata semantics and jq -e parity.
  defp falsy?(value), do: !Functions.jboolean(value)

  defp print_help do
    IO.puts("""
    Usage: jsonata [options] <expression> [file.json ...]

    Evaluate a JSONata expression against JSON input.

    Arguments:
      expression            JSONata expression to evaluate
      file.json             Input JSON file(s); reads stdin if omitted

    Options:
      -c, --compact         Compact output (default: pretty-printed)
      -r, --raw-output      Print strings without JSON quoting
      -n, --null-input      Use null as input; ignore stdin/files
      -e, --exit-status     Exit 1 if result is false, null, or empty
          --arg name value  Bind $name = "value" (string variable)
          --argjson name v  Bind $name = <json-value>
          --version         Print version and exit
      -h, --help            Print this help and exit

    Examples:
      echo '{"name":"Alice","age":30}' | jsonata '$.name'
      jsonata -r '$.name' data.json
      jsonata -n '$sum([1,2,3])'
      jsonata --arg name Alice -n '"Hello, " & $name'
    """)
  end
end
