defmodule Jsonata.Signature do
  @moduledoc """
  Function-signature parsing and argument validation, ported from `signature.js`.

  A signature such as `<s-nn?:s>` is compiled into a regular expression over the
  *type symbols* of the supplied arguments (`s` string, `n` number, `b` boolean,
  `l` null, `a` array, `o` object, `f` function, `m` missing). Validation matches
  the supplied arguments against that regex, then applies fix-ups: substituting
  the context value for a missing `-` parameter (T0411), wrapping singletons for
  array parameters, and raising T0410/T0412 on mismatch.
  """

  alias Jsonata.{Error, Function, Sequence}

  @type param :: %{
          regex: String.t(),
          type: String.t(),
          array: boolean(),
          context: boolean(),
          context_regex: Regex.t() | nil,
          subtype: String.t() | nil
        }

  @type t :: %{params: [param()], regex: Regex.t(), definition: String.t()}

  @doc "Parses a signature string (including the surrounding `<...>`) into a validator."
  @spec parse(String.t()) :: t()
  def parse(signature) when is_binary(signature) do
    params = parse_params(signature, 1, [])
    regex_str = "^" <> Enum.map_join(params, "", &"(#{&1.regex})") <> "$"
    %{params: params, regex: Regex.compile!(regex_str), definition: signature}
  end

  @doc """
  Validates and fixes up `args` for `signature`, using `context` for `-`
  parameters and `name` in error messages. Returns the validated argument list.
  """
  @spec validate(t(), [term()], term(), String.t()) :: [term()]
  def validate(%{params: params, regex: regex}, args, context, name) do
    supplied = Enum.map_join(args, "", &symbol/1)

    case Regex.run(regex, supplied) do
      nil -> raise validation_error(params, args, supplied, name)
      [_full | groups] -> fixup(params, groups, args, context, name)
    end
  end

  # --- parsing --------------------------------------------------------------

  defp parse_params(signature, pos, acc) when pos < byte_size(signature) do
    case binary_part(signature, pos, 1) do
      sym when sym in [":", ">"] -> Enum.reverse(acc)
      sym -> parse_symbol(sym, signature, pos, acc)
    end
  end

  defp parse_params(_signature, _pos, acc), do: Enum.reverse(acc)

  defp parse_symbol(sym, signature, pos, acc) when sym in ["s", "n", "b", "l", "o"],
    do: parse_params(signature, pos + 1, [new_param("[#{sym}m]", sym) | acc])

  defp parse_symbol("a", signature, pos, acc),
    do: parse_params(signature, pos + 1, [%{new_param("[asnblfom]", "a") | array: true} | acc])

  defp parse_symbol("f", signature, pos, acc),
    do: parse_params(signature, pos + 1, [new_param("f", "f") | acc])

  defp parse_symbol("j", signature, pos, acc),
    do: parse_params(signature, pos + 1, [new_param("[asnblom]", "j") | acc])

  defp parse_symbol("x", signature, pos, acc),
    do: parse_params(signature, pos + 1, [new_param("[asnblfom]", "x") | acc])

  defp parse_symbol("-", signature, pos, [prev | rest]) do
    prev = %{
      prev
      | context: true,
        context_regex: Regex.compile!(prev.regex),
        regex: prev.regex <> "?"
    }

    parse_params(signature, pos + 1, [prev | rest])
  end

  defp parse_symbol(sym, signature, pos, [prev | rest]) when sym in ["?", "+"],
    do: parse_params(signature, pos + 1, [%{prev | regex: prev.regex <> sym} | rest])

  defp parse_symbol("(", signature, pos, acc) do
    close = closing_bracket(signature, pos, "(", ")")
    choice = binary_part(signature, pos + 1, close - pos - 1)
    parse_params(signature, close + 1, [new_param("[#{choice}m]", "(#{choice})") | acc])
  end

  defp parse_symbol("<", signature, pos, [prev | rest]) do
    close = closing_bracket(signature, pos, "<", ">")
    subtype = binary_part(signature, pos + 1, close - pos - 1)
    parse_params(signature, close + 1, [%{prev | subtype: subtype} | rest])
  end

  defp parse_symbol(_sym, signature, pos, acc), do: parse_params(signature, pos + 1, acc)

  defp new_param(regex, type),
    do: %{
      regex: regex,
      type: type,
      array: false,
      context: false,
      context_regex: nil,
      subtype: nil
    }

  defp closing_bracket(str, start, open, close),
    do: closing_bracket(str, start + 1, open, close, 1)

  defp closing_bracket(str, pos, open, close, depth) do
    case binary_part(str, pos, 1) do
      ^close when depth == 1 -> pos
      ^close -> closing_bracket(str, pos + 1, open, close, depth - 1)
      ^open -> closing_bracket(str, pos + 1, open, close, depth + 1)
      _other -> closing_bracket(str, pos + 1, open, close, depth)
    end
  end

  # --- fix-up ---------------------------------------------------------------

  defp fixup(params, groups, args, context, name) do
    {validated, _index} =
      params
      |> Enum.zip(groups)
      |> Enum.reduce({[], 0}, fn {param, match}, {acc, index} ->
        fixup_param(param, match, args, context, name, acc, index)
      end)

    Enum.reverse(validated)
  end

  defp fixup_param(
         %{context: true, context_regex: cre} = _param,
         "",
         _args,
         context,
         name,
         acc,
         index
       )
       when not is_nil(cre) do
    if Regex.match?(cre, symbol(context)) do
      {[context | acc], index}
    else
      raise Error.new("T0411", value: context, index: index + 1, token: name)
    end
  end

  defp fixup_param(_param, "", args, _context, _name, acc, index),
    do: {[Enum.at(args, index, :undefined) | acc], index + 1}

  defp fixup_param(param, match, args, _context, _name, acc, index) do
    match
    |> String.graphemes()
    |> Enum.reduce({acc, index}, fn single, {a, i} ->
      arg = coerce(param, single, Enum.at(args, i, :undefined))
      {[arg | a], i + 1}
    end)
  end

  defp coerce(%{array: true}, "m", _arg), do: :undefined
  defp coerce(%{array: true}, "a", arg), do: arg
  defp coerce(%{array: true}, _single, arg), do: [arg]
  defp coerce(_param, _single, arg), do: arg

  # --- type symbols ---------------------------------------------------------

  defp symbol(%Function{}), do: "f"
  defp symbol(value) when is_function(value), do: "f"
  defp symbol(value) when is_binary(value), do: "s"
  defp symbol(value) when is_boolean(value), do: "b"
  defp symbol(value) when is_number(value), do: "n"
  defp symbol(nil), do: "l"
  defp symbol(:undefined), do: "m"
  defp symbol(%Sequence{} = seq), do: if(Enum.empty?(seq), do: "m", else: "a")
  defp symbol(value) when is_list(value), do: "a"
  defp symbol(value) when is_map(value), do: "o"
  defp symbol(_value), do: "m"

  # --- validation error (locate the first failing argument) -----------------

  defp validation_error(params, args, supplied, name) do
    index = first_failing_index(params, supplied, "^", 0)
    Error.new("T0410", value: Enum.at(args, index), index: index + 1, token: name)
  end

  defp first_failing_index([], _supplied, _pattern, good_to), do: good_to

  defp first_failing_index([param | rest], supplied, pattern, good_to) do
    pattern = pattern <> param.regex

    case Regex.run(Regex.compile!(pattern), supplied) do
      nil -> good_to
      [match | _] -> first_failing_index(rest, supplied, pattern, String.length(match))
    end
  end
end
